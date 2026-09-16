#!/usr/bin/env bash
# shellcheck disable=SC2034 # every variable here is consumed by the scripts that source this file
# Shared configuration for the arcade-webapp Niro harness.
#
# Sourced by start.sh / stop.sh / seed.sh / reset.sh. Every entry point is
# idempotent and safe to re-run: Niro may invoke any of them more than once
# during a run.
#
# Mutable runtime state (build output, SQLite DB, generated ROM corpus, PID and
# log) lives under niro/harness/run/ and is gitignored. The harness never
# writes into the checkout outside that directory.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HARNESS_DIR/../.." && pwd)"
APP_DIR="$REPO_ROOT/pkgs/arcade-webapp"

# The port is fixed by niro/scope.yaml (127.0.0.1:18094 / localhost:18094). The
# workflow's pre-flight smoke deliberately uses a DIFFERENT port (18095) so a
# leaked smoke listener can never occupy Niro's target. NIRO_APP_PORT exists
# only so a local experiment can move the app without editing committed files;
# Niro runs always use the committed default.
PORT="${NIRO_APP_PORT:-18094}"

RUN_DIR="$HARNESS_DIR/run"
BIN="$RUN_DIR/bin/arcade-webapp"
PID_FILE="$RUN_DIR/app.pid"
LOG_FILE="$RUN_DIR/app.log"
STATE_DIR="$RUN_DIR/state"
DB_FILE="$STATE_DIR/arcade-webapp.db"
GAMES_ROOT="$RUN_DIR/games"
DATS_DIR="$RUN_DIR/dats"
INCOMING_DIR="$RUN_DIR/incoming"
SCRATCH_DIR="$RUN_DIR/scratch"
CACHE_DIR="$RUN_DIR/skyscraper-cache"
BASE_URL="http://127.0.0.1:$PORT"

log()  { printf '[niro-harness] %s\n' "$*" >&2; }
fail() { printf '[niro-harness] ERROR: %s\n' "$*" >&2; exit 1; }

# Go toolchain resolution: CI supplies Go via actions/setup-go (the version
# comes from pkgs/arcade-webapp/go.mod); a bare NixOS checkout has no system Go,
# so fall back to the flake devShell (flake.lock pins the same toolchain).
# Callers run from REPO_ROOT so `nix develop` resolves this repository's flake.
GO_CMD=()
if command -v go >/dev/null 2>&1; then
  GO_CMD=(go)
elif command -v nix >/dev/null 2>&1; then
  GO_CMD=(nix develop -c go)
else
  fail "no go toolchain: install Go or run inside the flake devShell (nix develop)"
fi

# app_running: the recorded PID exists and is alive.
app_running() {
  [ -f "$PID_FILE" ] || return 1
  local pid
  pid="$(cat "$PID_FILE")"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# port_in_use: something is listening on $PORT. Prefers ss, then lsof, then a
# bash TCP connect probe. Used before start (refuse to fight over the port) and
# after stop (prove the port was actually released).
port_in_use() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$PORT\$"
  elif command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null
  fi
}

# wait_for_health [attempts]: poll /healthz once per second.
wait_for_health() {
  local attempts="${1:-60}" i
  for ((i = 1; i <= attempts; i++)); do
    if curl -fsS --max-time 2 "$BASE_URL/healthz" 2>/dev/null | grep -q '^ok'; then
      return 0
    fi
    sleep 1
  done
  return 1
}
