#!/usr/bin/env bash
#
# test-arcade-webapp.sh — VM test for the jupiterOS Arcade pipeline webapp
# (gauntlet plan §4 Phase 1 / AC-7's automated half).
#
# Builds the minimal test host tests/hosts/arcade-webapp-vm.nix (the REAL
# modules/services/arcade-webapp.nix against the deterministic fixture
# corpus), boots it headless, and greps the serial console for the
# in-VM smoke assertions' verdict. The smoke service inside the VM waits
# for /healthz, asserts the dashboard renders the fixture counts
# (nes 5 roms / 60% coverage, snes 4 / 100%, gb 4 / 0%), exercises
# /partials/* and POST /rescan, then prints the marker and powers off.
#
# Usage: make test-arcade-webapp   (or scripts/test-arcade-webapp.sh)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="arcade-webapp-vm"
OUT_LINK="result-vm-${HOST}"
# 600s (raised from 480 for P6): the smoke's verify gates now retry
# bounded (the post-verify launcher-DB regeneration can hold the shared
# slot when the next verify POST lands), and the P6 block adds ~8
# generate round-trips on top of the P3 real-igir invocations.
TIMEOUT_SECS="${TIMEOUT_SECS:-600}"

echo ">> Building VM for ${HOST}..."
nix build ".#nixosConfigurations.${HOST}.config.system.build.vm" \
  --option substituters "https://cache.nixos.org" \
  --option trusted-public-keys "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" \
  --out-link "${OUT_LINK}"

runner="$(echo "${OUT_LINK}"/bin/run-*-vm)"
if [[ ! -x "${runner}" ]]; then
  echo "!! No VM runner found for ${HOST} (${runner})" >&2
  exit 1
fi

logfile="${LOGFILE:-$(mktemp)}"
echo ">> Booting ${HOST} headless (timeout ${TIMEOUT_SECS}s); serial log: ${logfile}"

# HERMETIC DISK (P3 lesson): the stock build-vm runner defaults
# NIX_DISK_IMAGE to ./<host>.qcow2 resolved against the INVOKING cwd —
# every run would boot the SAME disk, and the webapp's SQLite state
# (verify_results, runs, staging) survives poweroff. A stale row from a
# previous debugging run made the fresh-tree P3 assertions lie (nes
# already 'unmatched' before any verify). One fresh disk per run; removed
# on exit.
diskdir="$(mktemp -d "${TMPDIR:-/tmp}/arcade-webapp-vm-disk.XXXXXXXXXX")"
export NIX_DISK_IMAGE="${diskdir}/disk.qcow2"
trap 'rm -rf "${diskdir}"' EXIT

# -nographic routes the serial console to stdout (captured); -no-reboot so
# the smoke service's `systemctl poweroff` ends the process cleanly.
QEMU_OPTS="-nographic -no-reboot" timeout "${TIMEOUT_SECS}" \
  "${runner}" -m 1024 -smp 2 >"${logfile}" 2>&1 &
vm_pid=$!

status=1
deadline=$((SECONDS + TIMEOUT_SECS))
while ((SECONDS < deadline)); do
  if grep -q "ARCADE-WEBAPP-VM: PASS" "${logfile}"; then
    echo ">> ${HOST}: in-VM smoke PASSED."
    status=0
    break
  fi
  if grep -q "ARCADE-WEBAPP-VM: FAIL" "${logfile}"; then
    echo "!! ${HOST}: in-VM smoke FAILED:" >&2
    grep "ARCADE-WEBAPP-VM: FAIL" "${logfile}" >&2 || true
    break
  fi
  if ! kill -0 "${vm_pid}" 2>/dev/null; then
    echo ">> VM process exited; checking the log for a verdict..."
    if grep -q "ARCADE-WEBAPP-VM: PASS" "${logfile}"; then
      echo ">> ${HOST}: in-VM smoke PASSED."
      status=0
    fi
    break
  fi
  sleep 3
done

# Tear the VM down (no-op if it already powered off).
kill "${vm_pid}" 2>/dev/null || true
wait "${vm_pid}" 2>/dev/null || true

if ((status != 0)); then
  echo "!! ${HOST} did not pass within ${TIMEOUT_SECS}s. Last 80 log lines:" >&2
  tail -n 80 "${logfile}" >&2
fi
exit "${status}"
