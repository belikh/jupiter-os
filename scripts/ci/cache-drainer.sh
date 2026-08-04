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

while true; do
  batch=""
  exec 9>"$lock"; flock 9
  if [ -s "$queue" ]; then batch="$(cat "$queue")"; : > "$queue"; fi
  exec 9>&-

  [ -z "$batch" ] && { sleep 3; continue; }
  paths="$(printf '%s\n' "$batch" | sort -u | grep -v '^$')" || true
  [ -z "$paths" ] && continue
  n="$(printf '%s\n' "$paths" | wc -l)"

  log "draining batch: $n path(s)"

  # xargs chunks to stay under ARG_MAX on a big backlog; timeout bounds each
  # transfer; retries absorb transient WG/NAR flakes. ssh-ng talks to europa's
  # nix daemon over the jupiter-ci SSH key.
  for attempt in 1 2 3 4 5 6; do
    log "attempt $attempt: pushing $n path(s)"
    if printf '%s\n' "$paths" | xargs -r -d '\n' timeout 600 \
        nix copy --to "ssh-ng://$ssh" 2>>/tmp/ci-drainer.err; then
      log "pushed $n path(s) on attempt $attempt"
      break
    else
      rc=$?
      log "attempt $attempt failed (rc=$rc); retry in $((attempt * 3))s"
      sleep $((attempt * 3))
    fi
  done
done