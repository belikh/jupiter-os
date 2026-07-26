#!/usr/bin/env bash
# Stands in for `make check` / `nix flake check --no-build`: rejects
# banned buildability-rule patterns, then records a digest of the current
# flake.lock as proof this ran against the *current* lock state.
set -euo pipefail
cd "$(dirname "$0")/.."

if grep -qE "hostPlatform\.gcc\.arch|jupiter\.build\.microarch" flake.nix 2>/dev/null; then
  echo "FAIL: buildability rule violated (microarch tuning present in flake.nix)"
  exit 1
fi

DIGEST=$(sha256sum flake.lock | cut -d' ' -f1)
echo "check: $DIGEST" > .check-passed
echo "PASS: eval clean for amalthea, metis (flake.lock digest $DIGEST)"
