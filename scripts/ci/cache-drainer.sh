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
# Destination store for `nix copy`. Defaults to jupiter-ci@europa (the CI
# receiver); the ci-distributed coordinator overrides to root@europa via
# EUROPA_STORE — the jupiter-ci key isn't reliably offered there, but
# root->europa is (the nom log already streams over it).
store="${EUROPA_STORE:-ssh-ng://jupiter-ci@europa}"
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

total_pushed=0

# Cumulative count of paths the post-build-hook has written into the FIFO, kept
# in a file the hook bumps atomically (flock) per write. This is the ONLY honest
# denominator for progress: a FIFO exposes no depth, and the drainer's own "how
# many I've read" is just "how many I've pushed +/- one in flight" — which is why
# the old total_queued-based percentage was pinned at 99-100% no matter how deep
# the real backlog was. Read fresh each time we log so it tracks the producer.
enqueue_cnt="${ENQUEUE_CNT:-/var/run/nix-push-enqueued}"
enqueue_count() { cat "$enqueue_cnt" 2>/dev/null || echo 0; }

# One status line: enqueued (producer total) | pushed (consumer total) |
# pending (real backlog = in-FIFO + in-flight + retrying) | honest progress %.
status_line() {
  local note="$1"
  local enq; enq=$(enqueue_count)
  local pending=$((enq - total_pushed)); [ "$pending" -lt 0 ] && pending=0
  local pct="-"; [ "$enq" -gt 0 ] && pct=$(( (total_pushed * 100) / enq ))
  log "$note | enqueued: $enq | pushed: $total_pushed | pending: $pending | progress: ${pct}%"
}

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
  status_line "pushing $n path(s)"

  for attempt in 1 2 3 4 5 6; do
    local err_file; err_file="$(mktemp)"
    if printf '%s\n' "$paths" | xargs -r -d '\n' timeout 600 env \
        NIX_SSHOPTS="-i $key -o ControlPath=$cm/%r@%h:%p -o StrictHostKeyChecking=accept-new" \
        "$nix_bin" copy --to "$store" 2>"$err_file"; then
      total_pushed=$((total_pushed + n))
      status_line "pushed $n path(s) on attempt $attempt"
      rm -f "$err_file"
      return
    else
      local rc=$?
      status_line "attempt $attempt failed (rc=$rc); retry in $((attempt * 3))s"
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
#
# ONE PATH AT A TIME. The FIFO is a stream of individual built paths (the
# post-build-hook writes one line per OUT_PATH); the drainer pushes each
# before reading the next, never batching. A previous version accumulated
# up to 64 paths into a single `nix copy`, so each transfer was huge: a
# batch sat in `nix copy` for the full 600s timeout and died rc=123, over
# and over, leaving almost nothing landed on europa. Per-path pushing keeps
# each `nix copy` small and fast (the ControlMaster socket reuses the SSH
# connection), and one path that genuinely needs the full 600s fails in
# isolation instead of dragging a whole batch back through the retry loop.
# fd 3's write half means the 3s read timeout never becomes an EOF, so the
# drainer never exits mid-run — it just re-loops on idle.
while true; do
  IFS=$'\t' read -r -t 3 STATUS STORE_PATH DERIVATION TIMESTAMP <&3 || continue
  [ -n "${STORE_PATH:-}" ] && flush "$STORE_PATH"
done
