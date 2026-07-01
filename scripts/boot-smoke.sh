#!/usr/bin/env bash
#
# Headless boot smoke test for a host. Builds the host's QEMU VM (the vmVariant
# already configured in modules/common.nix) and asserts it reaches
# multi-user.target within a timeout, then shuts it down. Used by CI and by
# `make boot-smoke-<host>`.
#
# This exercises more than `nix build` of the toplevel: the bootloader, the
# disko/impermanence filesystem story, and unit ordering all have to actually
# come up. Diskless hosts (callisto) are netboot images and are not VM-bootable
# this way — they're covered by the build job instead.
#
# Usage: scripts/boot-smoke.sh <host> [timeout-seconds]
set -euo pipefail

host="${1:?usage: boot-smoke.sh <host> [timeout-seconds]}"
timeout_secs="${2:-300}"

echo ">> Building VM for ${host}..."
nix build ".#nixosConfigurations.${host}.config.system.build.vm" \
  --out-link "result-vm-${host}"

runner="$(echo "result-vm-${host}"/bin/run-*-vm)"
if [[ ! -x "${runner}" ]]; then
  echo "!! No VM runner found for ${host} (${runner})" >&2
  exit 1
fi

logfile="$(mktemp)"
echo ">> Booting ${host} headless (timeout ${timeout_secs}s); serial log: ${logfile}"

# -nographic routes the serial console to stdout (captured); -no-reboot so a
# panic/halt ends the process instead of looping.
QEMU_OPTS="-nographic -no-reboot" timeout "${timeout_secs}" \
  "${runner}" -m 2048 -smp 2 >"${logfile}" 2>&1 &
vm_pid=$!

status=1
deadline=$((SECONDS + timeout_secs))
while ((SECONDS < deadline)); do
  if ! kill -0 "${vm_pid}" 2>/dev/null; then
    echo ">> VM process exited before reaching multi-user."
    break
  fi
  # systemd prints "Reached target Multi-User System." (wording varies slightly
  # across versions) — match loosely. Also match the getty login prompt
  # (e.g. "metis login:"): with console=ttyS0 (modules/common.nix's
  # vmVariant), systemd's own unit-status lines don't reliably show up on the
  # serial console, but serial-getty reaching a login prompt is equally solid
  # proof multi-user.target was hit — it only starts after that target.
  if grep -qiE "Reached target .*[Mm]ulti-?[Uu]ser|${host} login:" "${logfile}"; then
    echo ">> ${host} reached multi-user — boot OK."
    status=0
    break
  fi
  sleep 3
done

# Tear the VM down cleanly.
kill "${vm_pid}" 2>/dev/null || true
wait "${vm_pid}" 2>/dev/null || true

if ((status != 0)); then
  echo "!! ${host} did NOT reach multi-user within ${timeout_secs}s. Last 60 log lines:" >&2
  tail -n 60 "${logfile}" >&2
fi
exit "${status}"
