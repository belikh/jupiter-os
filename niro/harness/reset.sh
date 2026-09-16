#!/usr/bin/env bash
# Reset the harness to a clean baseline between Niro runs: stop the app, wipe
# all mutable state (build output, SQLite DB, generated corpus, logs, generated
# credentials and fixtures), then start and re-seed from the committed sources.
set -euo pipefail
# shellcheck source=niro/harness/env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$REPO_ROOT"

"$HARNESS_DIR/stop.sh"

rm -rf "$RUN_DIR"
rm -f "$REPO_ROOT/niro/credentials.yaml" "$REPO_ROOT/niro/fixtures.yaml"

"$HARNESS_DIR/start.sh"
"$HARNESS_DIR/seed.sh"

log "reset complete"
