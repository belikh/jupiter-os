#!/usr/bin/env bash
#
# Async binary-cache pusher for CI ("cache-drainer" for historical reasons —
# it drains the post-build-hook FIFO INTO europa's cache; it fills, not drains).
#   fast thread:  short timeout (300s), primary consumer of the FIFO
#   slow thread:  long timeout (1200s), handles paths that timed out in fast
#
# INPUT FIFO (/var/run/nix-push-fifo): tab-delimited lines from post-build-hook:
#   STATUS  STORE_PATH  DERIVATION  TIMESTAMP
# SLOW FIFO (/var/run/nix-push-fifo.slow): newline-separated store paths.
#
# BOMB-PROOFING RULES (learned from run 32646367507):
# 1. No silent defaults: EUROPA_SSH / EUROPA_KEY / EUROPA_STORE must be set or
#    we refuse to start. The old default alias `europa-ci` was never defined
#    anywhere and made every push fail invisibly.
# 2. All drainer-WRITTEN state lives in a directory WE verify is writable.
#    /var/run is root-owned on GH runners; the pushed-counter silently failing
#    to write there pinned progress at 0% for entire runs. Root-written files
#    (the FIFO and ENQUEUE_CNT) are only ever READ by us.
# 3. Single-instance guard: a pidfile with a live-check refuses to start twice.
#    A stale twin shares the FIFO and halves throughput while corrupting the
#    counters of both instances.
# 4. Failures are NEVER silent: nix's stdout+stderr are captured and shipped,
#    and every 10th consecutive failure ships a host snapshot (disk/mem/inodes)
#    so environment death (disk-full/OOM) is diagnosable from europa alone —
#    GH job logs die with the runner ("BlobNotFound").
# 5. SIGTERM/SIGINT finish the in-flight push and log an exit summary instead
#    of dying mid-transfer.
set -uo pipefail
umask 000

FAST_FIFO="${FAST_FIFO:-/var/run/nix-push-fifo}"
SLOW_FIFO="${SLOW_FIFO:-/var/run/nix-push-fifo.slow}"

# -- REQUIRED configuration (rule 1) -----------------------------------------
ssh="${EUROPA_SSH:-}"
key="${EUROPA_KEY:-}"
store="${EUROPA_STORE:-}"
nix_bin="${NIX_BIN:-$(command -v nix || true)}"
missing=""
[ -z "$ssh" ] && missing="$missing EUROPA_SSH"
[ -z "$key" ] && missing="$missing EUROPA_KEY"
[ -z "$store" ] && missing="$missing EUROPA_STORE"
[ -z "$nix_bin" ] && missing="$missing NIX_BIN"
if [ -n "$missing" ]; then
  echo "FATAL: pusher refusing to start, missing env:$missing (no silent defaults)" >&2
  exit 2
fi
[ -r "$key" ] || { echo "FATAL: EUROPA_KEY not readable: $key" >&2; exit 2; }
[ -x "$nix_bin" ] || { echo "FATAL: NIX_BIN not executable: $nix_bin" >&2; exit 2; }

# -- Writable state dir (rule 2) ----------------------------------------------
# Root-written inputs are read from their canonical /var/run locations; anything
# WE write goes to a directory proven writable at startup.
ENQUEUE_CNT="${ENQUEUE_CNT:-/var/run/nix-push-enqueued}"
state="${PUSHER_STATE_DIR:-}"
if [ -z "$state" ]; then
  for cand in /var/run/jupiter-ci-push "${TMPDIR:-/tmp}/jupiter-ci-push"; do
    if mkdir -p "$cand" 2>/dev/null && [ -w "$cand" ]; then state="$cand"; break; fi
  done
fi
if [ -z "$state" ] || [ ! -w "$state" ]; then
  echo "FATAL: no writable state dir found (tried /var/run/jupiter-ci-push, ${TMPDIR:-/tmp}/jupiter-ci-push)" >&2
  exit 2
fi

pidfile="$state/pusher.pid"
pushed_cnt="$state/pushed"

log_path="/var/log/jupiter-ci/cache-drainer.log"
cm="${EUROPA_CONTROLMASTERS:-$HOME/.ssh/controlmasters}"

FAST_TIMEOUT=300
SLOW_TIMEOUT=1200
SUMMARY_EVERY=120
SNAPSHOT_EVERY=10   # ship df/free snapshot on every Nth consecutive failure

# Lines logged before tailnet join (startup, config) cannot ship — ssh to
# europa is unroutable then. Buffer them and flush on first successful ship,
# otherwise the europa-side log permanently lacks the startup block.
_buffer="${state}/unshipped"

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
  local msg="[cache-push $(date -u +%H:%M:%S)] $*"
  echo "$msg"
  log_to_europa "$msg"
}

# -- Single-instance guard (rule 3) -------------------------------------------
if [ -f "$pidfile" ]; then
  old=$(cat "$pidfile" 2>/dev/null || true)
  if [ -n "$old" ] && [ "$old" != "$$" ] && kill -0 "$old" 2>/dev/null; then
    log "FATAL: another pusher (pid $old) is already running — refusing to start a twin"
    exit 3
  fi
fi
echo $$ > "$pidfile" 2>/dev/null || { echo "FATAL: cannot write pidfile $pidfile" >&2; exit 2; }
[[ -f "$pushed_cnt" ]] || echo 0 > "$pushed_cnt"

# -- Graceful shutdown (rule 5) ------------------------------------------------
STOP_REQUESTED=0
on_stop_signal() { STOP_REQUESTED=1; }
trap on_stop_signal TERM INT

total_pushed=0
enqueue_count() { cat "$ENQUEUE_CNT" 2>/dev/null || echo 0; }

status_line() {
  local note="$1"
  local enq; enq=$(enqueue_count)
  local pending=$((enq - total_pushed)); [ "$pending" -lt 0 ] && pending=0
  local pct="-"; [ "$enq" -gt 0 ] && pct=$(( (total_pushed * 100) / enq ))
  log "$note | enqueued: $enq | pushed: $total_pushed | pending: $pending | progress: ${pct}%"
}

host_snapshot() {
  # One compact line each: what died-with-the-runner incidents need.
  log "SNAPSHOT disk: $(df -h / /tmp 2>/dev/null | tail -n +2 | tr '\n' ' ') inodes: $(df -i / /tmp 2>/dev/null | tail -n +2 | awk '{print $5}' | tr '\n' ' ') mem: $(free -m 2>/dev/null | awk '/Mem:|Swap:/{printf "%s=%s/%s ", $1, $3, $2}') load: $(uptime | sed 's/.*load average/load average/')"
}

flush() {
  local path="$1"
  local timeout_sec="$2"
  local tag="$3"
  [ -z "$path" ] && return 0

  local err_file; err_file="$(mktemp "${state}/pusherr.XXXXXX")"
  # Direct exec, NO xargs: we push exactly one path per call, and xargs
  # rewrites every child exit code in 1-125 to 123 — which is how old logs
  # showed an undiagnosable wall of rc=123. Here rc is honest:
  # 124 = our timeout fired (candidate for the slow queue), anything else
  # is nix's/ssh's own failure code. BOTH stdout and stderr are captured
  # (rule 4): nix occasionally reports fatal errors on stdout.
  if timeout "$timeout_sec" env \
      NIX_SSHOPTS="-i $key -o ControlPath=$cm/%r@%h:%p -o StrictHostKeyChecking=accept-new" \
      "$nix_bin" copy --to "$store" "$path" >"$err_file.out" 2>"$err_file.err"; then
    total_pushed=$((total_pushed + 1))
    consecutive_failures=0
    rm -f "$err_file" "$err_file.out" "$err_file.err"
    return 0
  else
    # rc MUST be captured in the else branch: after a taken-then/untaken-else
    # `fi`, $? resets to 0 and every failure would log as rc=0.
    local rc=$?
    status_line "$tag: push failed (rc=$rc) $path"
    local err_tail
    err_tail=$(cat "$err_file.err" "$err_file.out" 2>/dev/null | tr '\n' ' ' | cut -c1-500)
    if [ -n "$err_tail" ]; then
      log "  err: $err_tail"
    else
      # Empty output AND failed = the most suspicious class of failure
      # (environment dying under us). Say so explicitly.
      log "  err: <EMPTY> nix produced no output at all — host likely starving (disk/mem); see SNAPSHOT lines"
    fi
    consecutive_failures=$((consecutive_failures + 1))
    if [ $((consecutive_failures % SNAPSHOT_EVERY)) -eq 0 ]; then
      host_snapshot
    fi
    rm -f "$err_file" "$err_file.out" "$err_file.err"
    # One-shot probe: separates auth/network breakage from store-protocol
    # rejection (e.g. require-sigs) without re-running the transfer.
    ssh -o ControlPath="$cm/%r@%h:%p" -o ConnectTimeout=10 "$ssh" true 2>/dev/null
    log "  probe: ssh $ssh -> rc=$?"
    return "$rc"
  fi
}
consecutive_failures=0

exec 3<>"$FAST_FIFO"
exec 4<>"$SLOW_FIFO"

requeue=()
declare -A attempts

slow_drainer() {
  log "slow thread started (reading from $SLOW_FIFO)"
  # NO idle heartbeat: liveness is observable from push timestamps and the
  # exit summary; periodic "still alive" lines were pure log spam.
  while true; do
    if [ "$STOP_REQUESTED" = 1 ]; then exit 0; fi
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
  log "ERROR: slow thread (PID $SLOW_PID) died at startup — timeouts will pile up unread"
fi

# Classify a failed fast push: genuine timeout (rc=124) graduates to the slow
# FIFO; any other failure stays in the fast requeue list with escalating
# backoff. Top-level loop helpers use NO `local` outside functions — under
# set -u an unset var here would kill the pusher on the first failure.
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
  if [ "$STOP_REQUESTED" = 1 ]; then
    status_line "stop signal received — exiting after ${total_pushed} pushes; requeue backlog: ${#requeue[@]} (final completeness push is the workflow's job)"
    rm -f "$pidfile"
    kill "$SLOW_PID" 2>/dev/null
    exit 0
  fi
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
    # Fully idle: silence. Liveness is observable from push timestamps and
    # the exit summary; periodic "still alive" lines were pure log spam.
    sleep 3
  fi
done
