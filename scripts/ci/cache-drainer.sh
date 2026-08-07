#!/usr/bin/env bash
#
# Background cache drainer for CI. Pops batches from the post-build-hook's
# queue and `nix copy`s them into europa's /nix/store over SSH (Harmonia then
# serves them to the fleet + the next CI run). Decoupled from nix's build
# loop so push health — WireGuard latency, large NARs — never stalls the
# build. Ported from build-server.nix's pusherLoop.
#
# Does ALL logging to europa via SSH (uses ControlMaster from CI workflow).
# Start BEFORE `nix build` (nohup ... &), kill (pkill -f cache-drainer.sh)
# after. retain-recent.sh does the final toplevel copy + GC-root pinning as a
# safety net for the one path that must be cached. Only meaningful on pushes
# to main (where WireGuard to europa is up); on PR runs this script is never
# started and the queue harmlessly accumulates into the ephemeral /tmp.
set -uo pipefail
umask 000

queue="${QUEUE_FILE:-/tmp/ci-cache-queue.txt}"
lock="${QUEUE_LOCK:-/tmp/ci-cache-queue.lock}"
ssh="${EUROPA_SSH:-europa-ci}"   # ~/.ssh/config alias -> jupiter-ci@10.1.1.2
log_path="/var/log/jupiter-ci/cache-drainer.log"
# `sudo` (this script's invoker) resets PATH to its own secure_path, which
# doesn't include wherever install-nix-action put `nix` — confirmed live:
# "env: 'nix': No such file or directory" on every single attempt. `ssh`
# works fine bare since /usr/bin is on secure_path; `nix` isn't. The caller
# resolves and passes the real path; fall back to a bare name (PATH lookup)
# if run standalone outside that wrapper.
nix_bin="${NIX_BIN:-nix}"

# Log to europa via SSH (uses ControlMaster from CI workflow)
log_to_europa() {
  local msg="$1"
  ssh -o ControlPath="/root/.ssh/controlmasters/%r@%h:%p" "$ssh" \
    "mkdir -p /var/log/jupiter-ci && echo \"$msg\" >> $log_path" 2>/dev/null || true
}

# Also log locally for console visibility
log() {
  local msg="[drainer $(date -u +%H:%M:%S)] $*"
  echo "$msg"
  log_to_europa "$msg"
}

touch "$queue" "$lock"; chmod 666 "$queue" "$lock"
: > "$queue"

log "drainer started"

total_queued=0
total_pushed=0

while true; do
  batch=""
  exec 9>"$lock"; flock 9
  if [ -s "$queue" ]; then batch="$(cat "$queue")"; : > "$queue"; fi
  exec 9>&-

  [ -z "$batch" ] && { sleep 3; continue; }
  paths="$(printf '%s\n' "$batch" | sort -u | grep -v '^$')" || true
  [ -z "$paths" ] && continue
  n="$(printf '%s\n' "$paths" | wc -l)"
  total_queued=$((total_queued + n))

  pct=0
  if [ "$total_queued" -gt 0 ]; then
    pct=$(( (total_pushed * 100) / total_queued ))
  fi
  log "draining batch: $n path(s) | queued: $total_queued | pushed: $total_pushed | progress: $pct%"

  # xargs chunks to stay under ARG_MAX on a big backlog; timeout bounds each
  # transfer; retries absorb transient WG/NAR flakes. ssh-ng talks to europa's
  # nix daemon over the jupiter-ci SSH key.
  #
  # MUST pass -i explicitly via NIX_SSHOPTS. Confirmed live by direct
  # reproduction (a manual ssh-ng copy with an explicit -key succeeded
  # instantly — PATH, nix-daemon, auth are all fine): the earlier
  # ssh-ng://$ssh form relied on the "europa-ci" SSH CONFIG ALIAS purely
  # for its `IdentityFile $HOME/.ssh/europa_ci` line (root has no default
  # ~/.ssh/id_* key at all). A prior "fix" here swapped to an explicit
  # jupiter-ci@europa target to dodge a suspected alias-resolution problem,
  # but that also silently dropped the IdentityFile, leaving ssh with no
  # key to offer at all — an immediate, fast auth failure indistinguishable
  # in symptom (rc=123, ~1s) from the original hypothesis. Keep the
  # explicit hostname AND explicitly supply the identity file — don't rely
  # on alias resolution for anything.
  for attempt in 1 2 3 4 5 6; do
    log "attempt $attempt: pushing $n path(s)"
    err_file="$(mktemp)"
    if printf '%s\n' "$paths" | xargs -r -d '\n' timeout 600 env \
        NIX_SSHOPTS="-i /root/.ssh/europa_ci -o ControlPath=/root/.ssh/controlmasters/%r@%h:%p -o StrictHostKeyChecking=accept-new" \
        "$nix_bin" copy --to "ssh-ng://jupiter-ci@europa" 2>"$err_file"; then
      total_pushed=$((total_pushed + n))
      pct=0
      if [ "$total_queued" -gt 0 ]; then
        pct=$(( (total_pushed * 100) / total_queued ))
      fi
      log "pushed $n path(s) on attempt $attempt | queued: $total_queued | pushed: $total_pushed | progress: $pct%"
      rm -f "$err_file"
      break
    else
      rc=$?
      log "attempt $attempt failed (rc=$rc); retry in $((attempt * 3))s"
      # DIAGNOSTIC: ship the real stderr to europa's log — two prior "fixes"
      # here both guessed wrong about the cause, so stop guessing and log
      # the actual error text instead of just the wrapper's rc=123.
      while IFS= read -r line; do log "  stderr: $line"; done < "$err_file"
      rm -f "$err_file"
      sleep $((attempt * 3))
    fi
  done
done