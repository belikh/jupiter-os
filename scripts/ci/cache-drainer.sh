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
# LOGGING DISCIPLINE: log events, not state. One completion line per push
# (with duration); failures log immediately with their real error. NO idle
# heartbeat — liveness is observable from completion timestamps (and the
# workflow's final nix copy is the completeness backstop), and periodic
# "still alive" lines were flooding the log while proving nothing.
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

# Both counters live in files so the fast drainer and the slow drainer (a
# forked subshell) report the SAME numbers. History: total_pushed was a plain
# variable, so the slow drainer's status lines showed "enqueued: N, pushed: 0"
# forever — it could never see the fast drainer's successes.
enqueue_cnt="${ENQUEUE_CNT:-/var/run/nix-push-enqueued}"
pushed_cnt="${PUSHED_CNT:-/var/run/nix-push-pushed}"
[[ -f "$pushed_cnt" ]] || echo 0 > "$pushed_cnt"
enqueue_count() { cat "$enqueue_cnt" 2>/dev/null || echo 0; }
record_push() {
  # flock subshell: `local` is illegal outside a function, so use a plain var.
  ( flock 9
    n=$(cat "$pushed_cnt" 2>/dev/null); n=${n:-0}
    echo $((n + 1)) > "$pushed_cnt" ) 9>"$pushed_cnt.lock"
}
pushed_count() { cat "$pushed_cnt" 2>/dev/null || echo 0; }

status_line() {
  local note="$1"
  local enq; enq=$(enqueue_count)
  local pushed; pushed=$(pushed_count)
  local pending=$((enq - pushed)); [ "$pending" -lt 0 ] && pending=0
  local pct="-"; [ "$enq" -gt 0 ] && pct=$(( (pushed * 100) / enq ))
  log "$note | enqueued: $enq | pushed: $pushed | pending: $pending | progress: ${pct}%"
}

flush() {
  local path="$1"
  local timeout_sec="$2"
  local tag="$3"
  [ -z "$path" ] && return 0
  local started=$SECONDS

  local err_file; err_file="$(mktemp)"
  # Direct exec, NO xargs: we push exactly one path per call, and xargs
  # rewrites every child exit code in 1-125 to 123 — which is how the old
  # logs showed an undiagnosable wall of rc=123. Here rc is honest:
  # 124 = our timeout fired (candidate for the slow queue), anything else
  # is nix's/ssh's own failure code.
  if timeout "$timeout_sec" env \
      NIX_SSHOPTS="-i $key -o ControlPath=$cm/%r@%h:%p -o StrictHostKeyChecking=accept-new" \
      "$nix_bin" copy --to "$store" "$path" >/dev/null 2>"$err_file"; then
    record_push
    rm -f "$err_file"
    log "$tag: pushed $path ($(( SECONDS - started ))s)"
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
retry_not_before=0

slow_drainer() {
  log "slow drainer started (reading from $SLOW_FIFO)"
  while true; do
    if IFS= read -r -t 5 STORE_PATH <&4; then
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

while true; do
  if IFS=$'\t' read -r -t 3 STATUS STORE_PATH DERIVATION TIMESTAMP <&3; then
    [ -z "${STORE_PATH:-}" ] && continue
    flush "$STORE_PATH" "$FAST_TIMEOUT" "fast" \
      && unset "attempts[$STORE_PATH]" \
      || handle_fast_failure "$STORE_PATH" "$?"
  elif [ "${#requeue[@]}" -gt 0 ]; then
    # Backoff: don't hammer a failing path every 3s read-timeout tick.
    retry="${requeue[0]}"
    wait_secs=$(( ${attempts[$retry]:-1} * 30 )); [ "$wait_secs" -gt 600 ] && wait_secs=600
    now=$(date +%s)
    if [ $((now - retry_not_before)) -lt "$wait_secs" ]; then sleep 3; continue; fi
    requeue=("${requeue[@]:1}")
    flush "$retry" "$FAST_TIMEOUT" "fast-retry" \
      && unset "attempts[$retry]" \
      || handle_fast_failure "$retry" "$?"
    retry_not_before=$(date +%s)
  else
    sleep 3
  fi
done
