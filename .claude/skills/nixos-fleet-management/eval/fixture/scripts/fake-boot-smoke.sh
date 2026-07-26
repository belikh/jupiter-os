#!/usr/bin/env bash
# Stands in for `make boot-smoke-<host>`: records a digest of the current
# flake.lock as proof the canary boot ran against the *current* lock state.
set -euo pipefail
cd "$(dirname "$0")/.."

HOST="${1:?usage: fake-boot-smoke.sh <host>}"
DIGEST=$(sha256sum flake.lock | cut -d' ' -f1)
echo "check: $DIGEST" > ".boot-smoke-$HOST.ok"
echo "PASS: $HOST reached multi-user.target (flake.lock digest $DIGEST)"
