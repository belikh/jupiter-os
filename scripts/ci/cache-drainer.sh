#!/usr/bin/env bash
#
# Async cache drainer for CI — two-threaded version.
#   fast drainer:  short timeout (300s), handles small/normal NARs
#   slow drainer:  long timeout (1200s), handles paths that timed out in fast
# Both read from the post-build-hook FIFO; fast drainer is the primary consumer.
# Slow drainer reads from a second FIFO that fast drainer writes timeouts to.
#
# INPUT FIFO (/var/run/nix-push-fifo): tab-delimited lines from post-build-hook:
#   STATUS  STORE_PATH  DERIVATION  TIMESTAMP
# SLOW FIFO (/var/run/nix-push-fifo.slow): newline-separated store paths.
#
# Runs as root on GitHub runners (sudo). SSH config/keys at /root/.ssh/.
# Start BEFORE `nix build` (nohup ... &) so FIFO has a reader immediately.
set -uo pipefail
umask 000

FAST_FIFO="${FAST_FIFO:-/var/run/nix-push-fifo}"
SLOW_FIFO="${SLOW_FIFO:-/var/run/nix-push-fifo.slow}"
ssh="${EUROPA_SSH:-europa-ci}"
key="${EUROPA_KEY:-$HOME/.ssh/europa_ci}"
cm="${EUROPA_CONTROLMASTERS:-$HOME/.ssh/controlmasters}"
store="${EUROPA_STORE:-ssh-ng://europa-ci}"
log_path="/var/log/jupiter-ci/cache-drainer.log"
nix_bin="${NIX_BIN:-nix}"

FAST_TIMEOUT=300
SLOW_TIMEOUT=1200

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

[[ -p "$FAST_FIFO" ]] || mkfifo -m 666 "$FAST_FIFO"
[[ -p "$SLOW_FIFO" ]] || mkfifo -m 666 "$SLOW_FIFO"

log "drainer started (fast: ${FAST_TIMEOUT}s, slow: ${SLOW_TIMEOUT}s)"

total_pushed=0
enqueue_cnt="${ENQUEUE_CNT:-/var/run/nix-push-enqueued}"
enqueue_count() { cat "$enqueue_cnt" 2>/dev/null || echo 0; }

status_line() {
  local note="$1"
  local enq; enq=$(enqueue_count)
  local pending=$((enq - total_pushed)); [ "$pending" -lt 0 ] && pending=0
  local pct="-"; [ "$enq" -gt 0 ] && pct=$(( (total_pushed * 100) / enq ))
  log "$note | enqueued: $enq | pushed: $total_pushed | pending: $pending | progress: ${pct}%"
}

flush() {
  local paths="$1"
  local timeout_sec="$2"
  local tag="$3"
  [ -z "$paths" ] && return 0
  paths="$(printf '%s\n' "$paths" | sort -u | grep -v '^$')" || true
  [ -z "$paths" ] && return 0
  local n; n=$(printf '%s\n' "$paths" | wc -l)
  status_line "$tag: pushing $n path(s) (timeout ${timeout_sec}s)"

  local err_file; err_file="$(mktemp)"
  if printf '%s\n' "$paths" | xargs -r -d '\n' timeout "$timeout_sec" env \
      NIX_SSHOPTS="-i $key -o ControlPath=$cm/%r@%h:%p -o StrictHostKeyChecking=accept-new" \
      "$nix_bin" copy --to "$store" 2>"$err_file"; then
    total_pushed=$((total_pushed + n))
    status_line "$tag: pushed $n path(s)"
    rm -f "$err_file"
    return 0
  else
    local rc=$?
    status_line "$tag: push failed (rc=$rc); re-queuing"
    while IFS= read -r line; do log "  stderr: $line"; done < "$err_file"
    rm -f "$err_file"
    return $rc
  fi
}

exec 3<>"$FAST_FIFO"
exec 4<>"$SLOW_FIFO"

requeue=()

slow_drainer() {
  log "slow drainer started (reading from $SLOW_FIFO)"
  while true; do
    if IFS= read -r -t 5 STORE_PATH <&4; then
      [ -z "${STORE_PATH:-}" ] && continue
      flush "$STORE_PATH" "$SLOW_TIMEOUT" "slow" || {
        log "slow drainer: $STORE_PATH failed even with long timeout, re-queuing to slow"
        printf '%s\n' "$STORE_PATH" >&4
      }
    fi
  done
}

slow_drainer &
SLOW_PID=$!
log "slow drainer PID: $SLOW_PID"

while true; do
  if IFS=$'\t' read -r -t 3 STATUS STORE_PATH DERIVATION TIMESTAMP <&3; then
    [ -z "${STORE_PATH:-}" ] && continue
    flush "$STORE_PATH" "$FAST_TIMEOUT" "fast" || {
      local rc=$?
      if [ "$rc" -eq 124 ]; then
        log "fast drainer: $STORE_PATH timed out after ${FAST_TIMEOUT}s -> moving to slow FIFO"
        printf '%s\n' "$STORE_PATH" >&4
      else
        requeue+=("$STORE_PATH")
      fi
    }
  elif [ "${#requeue[@]}" -gt 0 ]; then
    retry="${requeue[0]}"; requeue=("${requeue[@]:1}")
    flush "$retry" "$FAST_TIMEOUT" "fast-retry" || {
      local rc=$?
      if [ "$rc" -eq 124 ]; then
        log "fast drainer retry: $retry timed out -> moving to slow FIFO"
        printf '%s\n' "$retry" >&4
      else
        requeue+=("$retry")
      fi
    }
  fi
done