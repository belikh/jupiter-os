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
#
# LOGGING DISCIPLINE: quiet by default. Successful pushes log nothing; all
# activity collapses into one summary line every SUMMARY_EVERY seconds. Only
# failures log immediately (status + one truncated err line + ssh probe).
# History: per-event logging produced a wall of near-identical lines that hid
# the one line that mattered.
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
SUMMARY_EVERY=120

# Lines logged before tailnet join (startup, config) cannot ship — ssh to
# europa is unroutable then. Buffer them and flush on first successful ship,
# otherwise the europa-side log permanently lacks the startup block.
_buffer="${TMPDIR:-/tmp}/cache-drainer-unshipped"

log_to_europa() {
  local msg="$1"
  # base64 round-trip: `echo "$msg"` breaks on any line containing quotes,
  # $ or backticks (remote shell syntax error, swallowed by || true) — exactly
  # what nix error lines contain, so real failure reasons never landed.
  local b64
  b64=$(printf '%s\n' "$msg" | base64 -w0) || return 0
  if [ -s "$_buffer" ]; then
    ssh -o ControlPath="$cm/%r@%h:%p" -o ConnectTimeout=10 "$ssh" \
      "mkdir -p /var/log/jupiter-ci && cat >> $log_path" <"$_buffer" 2>/dev/null \
      && : > "$_buffer"
  fi
  printf '%s\n' "$b64" | ssh -o ControlPath="$cm/%r@%h:%p" -o ConnectTimeout=10 \
    "$ssh" "mkdir -p /var/log/jupiter-ci && base64 -d >> $log_path" 2>/dev/null \
    || printf '%s\n' "$msg" >> "$_buffer"
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
  local path="$1"
  local timeout_sec="$2"
  local tag="$3"
  [ -z "$path" ] && return 0

  local err_file; err_file="$(mktemp)"
  # Direct exec, NO xargs: we push exactly one path per call, and xargs
  # rewrites every child exit code in 1-125 to 123 — which is how the old
  # logs showed an undiagnosable wall of rc=123. Here rc is honest:
  # 124 = our timeout fired (candidate for the slow queue), anything else
  # is nix's/ssh's own failure code.
  if timeout "$timeout_sec" env \
      NIX_SSHOPTS="-i $key -o ControlPath=$cm/%r@%h:%p -o StrictHostKeyChecking=accept-new" \
      "$nix_bin" copy --to "$store" "$path" >/dev/null 2>"$err_file"; then
    total_pushed=$((total_pushed + 1))
    rm -f "$err_file"
    return 0
  else
    # rc MUST be captured in the else branch: after a taken-then/untaken-else
    # `fi`, $? resets to 0 and every failure would log as rc=0.
    local rc=$?
    status_line "$tag: push failed (rc=$rc) $path"
    # ONE line, not a per-line ssh flood; tail keeps the actual nix/ssh error
  # and drops the "copying path ..." progress noise above it.
    local err_tail; err_tail=$(tail -n 3 "$err_file" | tr '\n' ' ' | cut -c1-500)
    [ -n "$err_tail" ] && log "  err: $err_tail"
    rm -f "$err_file"
    # One-shot probe: separates auth/network breakage from store-protocol
    # rejection (e.g. require-sigs) without re-running the transfer.
    ssh -o ControlPath="$cm/%r@%h:%p" -o ConnectTimeout=10 "$ssh" true 2>/dev/null
    log "  probe: ssh $ssh -> rc=$?"
    return "$rc"
  fi
}

exec 3<>"$FAST_FIFO"
exec 4<>"$SLOW_FIFO"

requeue=()
declare -A attempts

slow_drainer() {
  log "slow drainer started (reading from $SLOW_FIFO)"
  local idle=0
  while true; do
    if IFS= read -r -t 5 STORE_PATH <&4; then
      idle=0
      [ -z "${STORE_PATH:-}" ] && continue
      if flush "$STORE_PATH" "$SLOW_TIMEOUT" "slow"; then
        unset "attempts[$STORE_PATH]"
      else
        # Backoff before re-queuing: an instantly-failing path must not
        # hot-spin this loop against europa.
        status_line "slow: $STORE_PATH failed at ${SLOW_TIMEOUT}s; retry in 60s"
        sleep 60
        printf '%s\n' "$STORE_PATH" >&4
      fi
    else
      # Heartbeat: proves the subshell is alive and the queue genuinely empty
      # (vs. this process wedged). Rate-limited to once per SUMMARY_EVERY.
      idle=$((idle + 1))
      if [ "$idle" -ge $((SUMMARY_EVERY / 5)) ]; then
        status_line "slow: idle"
        idle=0
      fi
    fi
  done
}

slow_drainer &
SLOW_PID=$!
if ! kill -0 "$SLOW_PID" 2>/dev/null; then
  log "ERROR: slow drainer (PID $SLOW_PID) died at startup — timeouts will pile up unread"
fi

# Classify a failed fast push: genuine timeout (rc=124) graduates to the slow
# FIFO; any other failure stays in the fast requeue list with escalating
# backoff. Top-level loop helpers use NO `local` outside functions — under
# set -u an unset var here would kill the drainer on the first failure.
handle_fast_failure() {
  local path="$1" rc="$2"
  if [ "$rc" -eq 124 ]; then
    printf '%s\n' "$path" >&4
  else
    attempts[$path]=$(( ${attempts[$path]:-0} + 1 ))
    requeue+=("$path")
  fi
}

last_summary=$(date +%s)
while true; do
  if IFS=$'\t' read -r -t 3 STATUS STORE_PATH DERIVATION TIMESTAMP <&3; then
    [ -z "${STORE_PATH:-}" ] && continue
    flush "$STORE_PATH" "$FAST_TIMEOUT" "fast" \
      && unset "attempts[$STORE_PATH]" \
      || handle_fast_failure "$STORE_PATH" "$?"
    last_summary=$(date +%s)
  elif [ "${#requeue[@]}" -gt 0 ]; then
    # Backoff: don't hammer a failing path every 3s read-timeout tick.
    retry="${requeue[0]}"
    wait_secs=$(( ${attempts[$retry]:-1} * 30 )); [ "$wait_secs" -gt 600 ] && wait_secs=600
    now=$(date +%s)
    if [ $((now - last_summary)) -lt "$wait_secs" ]; then sleep 3; continue; fi
    requeue=("${requeue[@]:1}")
    flush "$retry" "$FAST_TIMEOUT" "fast-retry" \
      && unset "attempts[$retry]" \
      || handle_fast_failure "$retry" "$?"
    last_summary=$(date +%s)
  else
    # Fully idle: one summary line per SUMMARY_EVERY instead of silence.
    now=$(date +%s)
    if [ $((now - last_summary)) -ge "$SUMMARY_EVERY" ]; then
      status_line "idle"
      last_summary=$now
    fi
    sleep 3
  fi
done
