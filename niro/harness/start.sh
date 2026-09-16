#!/usr/bin/env bash
# Start the arcade-webapp from the current checkout for a Niro run.
#
#   * builds the Go binary from pkgs/arcade-webapp into the gitignored run dir
#   * binds 0.0.0.0:18094 — Niro's attack container reaches the host listener
#     through the loopback mapping; a 127.0.0.1-only listener is unreachable
#     from the container on native Linux Docker
#   * starts the process in its own session (setsid) so stop.sh can kill the
#     whole process group, and records the group leader's PID
#   * waits for /healthz before returning; Niro treats a non-zero exit as a
#     failed start
#
# Idempotent: a second call while the app is healthy succeeds without
# rebuilding.
set -euo pipefail
# shellcheck source=niro/harness/env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$REPO_ROOT"

if app_running; then
  if wait_for_health 5; then
    log "arcade-webapp already running (pid $(cat "$PID_FILE")) on $BASE_URL"
    exit 0
  fi
  fail "pid $(cat "$PID_FILE") is alive but $BASE_URL/healthz is not answering"
fi

if port_in_use; then
  fail "$PORT is already bound by another process; refusing to start a second listener (orphaned smoke server? see scripts/niro-preflight.sh, or find the owner with: ss -ltnp | grep :$PORT)"
fi

mkdir -p "$RUN_DIR/bin" "$STATE_DIR" "$DATS_DIR" "$INCOMING_DIR" "$SCRATCH_DIR" "$CACHE_DIR" \
  "$GAMES_ROOT/cartridge" "$GAMES_ROOT/optical" "$GAMES_ROOT/modern"

log "building arcade-webapp from $APP_DIR"
"${GO_CMD[@]}" -C "$APP_DIR" build -o "$BIN" ./cmd/arcade-webapp

# Deterministic, offline test state: no aria2/igir/Skyscraper wiring, no
# scheduled DAT refreshes or scrapes (those reach third-party services and
# would make a run non-reproducible). See seed.sh for the fixture corpus.
export ARCADE_WEBAPP_ADDR="0.0.0.0:$PORT"
export ARCADE_WEBAPP_CATALOGUE_TSV="$REPO_ROOT/scripts/cartridge-catalogue.tsv"
export ARCADE_WEBAPP_CARTRIDGE_ROOT="$GAMES_ROOT/cartridge"
export ARCADE_WEBAPP_OPTICAL_ROOT="$GAMES_ROOT/optical"
export ARCADE_WEBAPP_MODERN_ROOT="$GAMES_ROOT/modern"
export ARCADE_WEBAPP_DAT_DIR="$DATS_DIR"
export ARCADE_WEBAPP_INCOMING_DIR="$INCOMING_DIR"
export ARCADE_WEBAPP_SCRATCH_DIR="$SCRATCH_DIR"
export ARCADE_WEBAPP_SKYSCRAPER_CACHE_DIR="$CACHE_DIR"
export ARCADE_WEBAPP_DB="$DB_FILE"
export ARCADE_WEBAPP_SCRAPE_INTERVAL_HOURS=0
export ARCADE_WEBAPP_DAT_REFRESH_HOURS=0

if command -v setsid >/dev/null 2>&1; then
  setsid "$BIN" >>"$LOG_FILE" 2>&1 &
else
  "$BIN" >>"$LOG_FILE" 2>&1 &
fi
echo $! >"$PID_FILE"
log "started pid $(cat "$PID_FILE") (log: $LOG_FILE)"

if ! wait_for_health 60; then
  log "app did not answer /healthz within 60s; last log lines:"
  tail -n 40 "$LOG_FILE" >&2 || true
  # Tear down the failed attempt so a retry starts clean and no orphan holds
  # the port.
  "$HARNESS_DIR/stop.sh" || true
  fail "arcade-webapp failed to become healthy on $BASE_URL"
fi
log "healthy on $BASE_URL"
