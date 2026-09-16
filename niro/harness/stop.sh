#!/usr/bin/env bash
# Stop the arcade-webapp started by start.sh.
#
# Cleanly: SIGTERM the whole process group (the app is started under setsid so
# wrappers that leave children bound to the port are all reaped), wait for
# exit, then SIGKILL the group if it will not go. Removes the PID file and
# verifies the port is released. Idempotent; also sweeps an orphan of our own
# built binary if the PID file was lost.
set -euo pipefail
# shellcheck source=niro/harness/env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$REPO_ROOT"

stop_pid() {
  local pid="$1" sig="$2"
  kill -"$sig" -- "-$pid" 2>/dev/null && return 0
  kill -"$sig" "$pid" 2>/dev/null # fallback: no process group (no setsid)
}

if [ -f "$PID_FILE" ]; then
  pid="$(cat "$PID_FILE" || true)"
  if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
    log "signalling process group $pid (SIGTERM)"
    stop_pid "$pid" TERM || true
    for _ in $(seq 1 50); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.2
    done
    if kill -0 "$pid" 2>/dev/null; then
      log "process group $pid still alive; SIGKILL"
      stop_pid "$pid" KILL || true
      sleep 0.5
    fi
  fi
  rm -f "$PID_FILE"
fi

# Lost PID file: sweep orphans of OUR built binary only. Match the process
# name, then confirm /proc/<pid>/exe resolves to exactly $BIN — a command-line
# match would also hit unrelated shells/builds that merely mention the path,
# and a bare name match could hit a dev instance elsewhere on the machine.
sweep() {
  local pid exe
  for pid in $(pgrep -x arcade-webapp 2>/dev/null); do
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    [ "$exe" = "$BIN" ] || continue
    kill -"$1" -- "-$pid" 2>/dev/null || kill -"$1" "$pid" 2>/dev/null || true
  done
}
if pgrep -x arcade-webapp >/dev/null 2>&1; then
  log "sweeping orphaned $(basename "$BIN") processes"
  sweep TERM
  for _ in $(seq 1 25); do
    pgrep -x arcade-webapp >/dev/null 2>&1 || break
    sleep 0.2
  done
  sweep KILL
fi

for _ in $(seq 1 25); do
  if ! port_in_use; then
    log "stopped; port $PORT is free"
    exit 0
  fi
  sleep 0.2
done
fail "port $PORT is still bound after stop; inspect with: ss -ltnp | grep :$PORT"
