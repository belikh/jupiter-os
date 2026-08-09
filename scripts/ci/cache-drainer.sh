#!/usr/bin/env bash
#
# Async cache drainer for CI. Reads completed store paths from the
# post-build-hook's FIFO and `nix copy`s them into europa's /nix/store over
# SSH (Harmonia then serves them to the fleet + the next CI run). Decoupled
# from nix's build loop so push health — Tailscale latency, large NARs —
# never stalls the build. Ported from build-server.nix's pusherLoop.
#
# INPUT IS THE FIFO (/var/run/nix-push-fifo) that post-build-hook.sh writes:
# one tab-delimited line per built output (STATUS, STORE_PATH, DERIVATION,
# TIMESTAMP). The FIFO is held open read+write on fd 3 — the write half keeps
# the read side from seeing EOF when the hook (the only other writer) closes
# between builds, so this loop stays alive for the whole CI run instead of
# dying after the first hook invocation. (The previous shape polled a plain
# file the hook never wrote, so the two were never connected and nothing ever
# got pushed.)
#
# Runs as the runner user on the distributed builders; the hook itself runs as
# root via nix-daemon, so the FIFO is mode 0666 (see post-build-hook.sh) and
# the SSH key/controlmaster paths are $HOME-based, not /root. Start BEFORE
# `nix build` (nohup ... &) so the FIFO has a reader before the first path is
# built; the drainer then reads for the whole CI window.
set -uo pipefail
umask 000

FIFO="${FIFO:-/var/run/nix-push-fifo}"
ssh="${EUROPA_SSH:-europa-ci}"   # ~/.ssh/config alias -> jupiter-ci@europa
key="${EUROPA_KEY:-$HOME/.ssh/europa_ci}"
cm="${EUROPA_CONTROLMASTERS:-$HOME/.ssh/controlmasters}"
log_path="/var/log/jupiter-ci/cache-drainer.log"
# `sudo` (this script's invoker) resets PATH to its own secure_path, which
# doesn't include wherever install-nix-action put `nix`. The caller resolves
# and passes the real path via NIX_BIN; fall back to a bare name (PATH lookup)
# if run standalone.
nix_bin="${NIX_BIN:-nix}"

log_to_europa() {
  local msg="$1"
  ssh -o ControlPath="$cm/%r@%h:%p" "$ssh" \
    "mkdir -p /var/log/jupiter-ci && echo \"$msg\" >> $log_path" 2>/dev/null || true
}

log() {
  local msg="[drainer $(date -u +%H:%M:%S)] $*"
  echo "$msg"
  log_to_europa "$msg"
}

# Ensure the FIFO exists. Mode 0666: the hook (root, via nix-daemon) writes
# and this drainer (runner on builders) reads — both must be able to open it.
[[ -p "$FIFO" ]] || mkfifo -m 666 "$FIFO"

log "drainer started, reading from $FIFO"

total_queued=0
total_pushed=0

# Push one batch (newline-separated store paths). Retries absorb transient
# Tailscale/NAR flakes; xargs chunks to stay under ARG_MAX; timeout bounds
# each transfer. ssh-ng talks to europa's nix daemon over the jupiter-ci key,
# supplied explicitly via NIX_SSHOPTS (don't rely on alias identity resolution
# for the ssh-ng spawn), reusing the ControlMaster socket the workflow warmed.
flush() {
  local paths="$1"
  [ -z "$paths" ] && return
  paths="$(printf '%s\n' "$paths" | sort -u | grep -v '^$')" || true
  [ -z "$paths" ] && return
  local n; n=$(printf '%s\n' "$paths" | wc -l)
  total_queued=$((total_queued + n))
  local pct=0
  if [ "$total_queued" -gt 0 ]; then pct=$(( (total_pushed * 100) / total_queued )); fi
  log "draining batch: $n path(s) | queued: $total_queued | pushed: $total_pushed | progress: $pct%"

  for attempt in 1 2 3 4 5 6; do
    log "attempt $attempt: pushing $n path(s)"
    local err_file; err_file="$(mktemp)"
    if printf '%s\n' "$paths" | xargs -r -d '\n' timeout 600 env \
        NIX_SSHOPTS="-i $key -o ControlPath=$cm/%r@%h:%p -o StrictHostKeyChecking=accept-new" \
        "$nix_bin" copy --to "ssh-ng://jupiter-ci@europa" 2>"$err_file"; then
      total_pushed=$((total_pushed + n))
      pct=0; [ "$total_queued" -gt 0 ] && pct=$(( (total_pushed * 100) / total_queued ))
      log "pushed $n path(s) on attempt $attempt | queued: $total_queued | pushed: $total_pushed | progress: $pct%"
      rm -f "$err_file"
      return
    else
      local rc=$?
      log "attempt $attempt failed (rc=$rc); retry in $((attempt * 3))s"
      # Ship the real stderr to europa's log — stop guessing at the cause.
      while IFS= read -r line; do log "  stderr: $line"; done < "$err_file"
      rm -f "$err_file"
      sleep $((attempt * 3))
    fi
  done
}

# Hold the FIFO open read+write (fd 3). The write half prevents EOF when the
# hook closes between builds, so the read loop spans the whole CI run rather
# than exiting after the first hook invocation.
exec 3<>"$FIFO"
batch=""
while true; do
  # Read one tab-delimited line from the hook, with a 3s idle timeout.
  #   line arrived  -> append STORE_PATH to the batch; flush at 64 paths.
  #   3s idle       -> flush whatever has accumulated, then keep waiting.
  # fd 3's write half means the timeout never becomes an EOF, so the drainer
  # never exits mid-run.
  if IFS=$'\t' read -r -t 3 STATUS STORE_PATH DERIVATION TIMESTAMP <&3; then
    if [ -n "${STORE_PATH:-}" ]; then
      batch="${batch:+$batch$'\n'}$STORE_PATH"
      if [ "$(printf '%s\n' "$batch" | wc -l)" -ge 64 ]; then
        flush "$batch"; batch=""
      fi
    fi
  else
    if [ -n "$batch" ]; then flush "$batch"; batch=""; fi
  fi
done
# Unreachable while fd 3 is held open; safety net only.
[ -n "$batch" ] && flush "$batch"
