#!/usr/bin/env bash
# Pre-flight for the Niro Find workflow: run the arcade-webapp's own CI lane
# (install + vet + race tests) and then a build + listen smoke on a SPARE port
# (18095), never on Niro's target port (18094).
#
# Port separation is deliberate: a leaked pre-flight server that orphaned on
# the target port would either block the harness bind or, worse, be tested
# instead of the harness instance. The smoke runs in its own process group, is
# torn down in an EXIT trap, and the spare port is asserted free before this
# script returns. niro/harness/*.sh use the same process-group discipline.
#
# Usage: scripts/niro-preflight.sh   (CI and local)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Reuse the harness's toolchain resolution, port probe and health poll so the
# pre-flight and the run itself cannot drift apart.
# shellcheck source=niro/harness/env.sh
source "$REPO_ROOT/niro/harness/env.sh"

# Never touch Niro's committed target port here.
PORT="${NIRO_PREFLIGHT_PORT:-18095}"
BASE_URL="http://127.0.0.1:$PORT"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/niro-preflight.XXXXXXXXXX")"
SMOKE_PID=""

cleanup() {
  if [ -n "$SMOKE_PID" ] && kill -0 "$SMOKE_PID" 2>/dev/null; then
    kill -TERM -- "-$SMOKE_PID" 2>/dev/null || kill -TERM "$SMOKE_PID" 2>/dev/null || true
    for _ in $(seq 1 25); do
      kill -0 "$SMOKE_PID" 2>/dev/null || break
      sleep 0.2
    done
    kill -KILL -- "-$SMOKE_PID" 2>/dev/null || kill -KILL "$SMOKE_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

cd "$REPO_ROOT"

if port_in_use; then
  fail "spare port $PORT is already bound before the smoke; refusing to reuse it"
fi

log "install: go mod download"
"${GO_CMD[@]}" -C "$APP_DIR" mod download

log "app CI: go vet"
"${GO_CMD[@]}" -C "$APP_DIR" vet ./...

log "app CI: go test -race"
"${GO_CMD[@]}" -C "$APP_DIR" test -race ./...

log "build: ./cmd/arcade-webapp"
"${GO_CMD[@]}" -C "$APP_DIR" build -o "$WORK_DIR/arcade-webapp" ./cmd/arcade-webapp

mkdir -p "$WORK_DIR/games/cartridge" "$WORK_DIR/dats" "$WORK_DIR/state"
export ARCADE_WEBAPP_ADDR="0.0.0.0:$PORT"
export ARCADE_WEBAPP_CATALOGUE_TSV="$REPO_ROOT/scripts/cartridge-catalogue.tsv"
export ARCADE_WEBAPP_CARTRIDGE_ROOT="$WORK_DIR/games/cartridge"
export ARCADE_WEBAPP_DAT_DIR="$WORK_DIR/dats"
export ARCADE_WEBAPP_DB="$WORK_DIR/state/arcade-webapp.db"
export ARCADE_WEBAPP_SCRAPE_INTERVAL_HOURS=0
export ARCADE_WEBAPP_DAT_REFRESH_HOURS=0

if command -v setsid >/dev/null 2>&1; then
  setsid "$WORK_DIR/arcade-webapp" >>"$WORK_DIR/smoke.log" 2>&1 &
else
  "$WORK_DIR/arcade-webapp" >>"$WORK_DIR/smoke.log" 2>&1 &
fi
SMOKE_PID=$!

if ! wait_for_health 60; then
  tail -n 40 "$WORK_DIR/smoke.log" >&2 || true
  fail "smoke server never answered /healthz on $BASE_URL"
fi

curl -fsS --max-time 5 "$BASE_URL/inventory.json" >/dev/null || fail "GET /inventory.json failed"
curl -fsS --max-time 5 "$BASE_URL/" >/dev/null || fail "GET / failed"
log "smoke ok: /healthz, / and /inventory.json answered on $BASE_URL"

cleanup
trap - EXIT
SMOKE_PID=""

if port_in_use; then
  fail "port $PORT is still bound after teardown; refusing to hand over to Niro"
fi
log "pre-flight complete; spare port $PORT released"
