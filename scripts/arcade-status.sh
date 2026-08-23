#!/usr/bin/env bash
# arcade-status.sh — dev convenience: pull the fleet arcade inventory and
# pretty-print a one-screen table. Intended for `make status-arcade`.
#
#   ./scripts/arcade-status.sh
#   ARCADE_WEBAPP_URL=http://10.1.1.2:8094 ./scripts/arcade-status.sh
#   ARCADE_STATUS_FALLBACK_SSH=0 ./scripts/arcade-status.sh   # webapp only
#
# Source (P8): the arcade-webapp serves the SAME document the retired
# jupiter-arcade-inventory unit used to write — field-for-field parity at
# http://<europa>:8094/inventory.json (internal/inventory pins the shape).
# The webapp endpoint is tried first; if it is unreachable AND fallback is
# enabled, we still read europa's legacy state file over SSH so status
# keeps working across the transition (and on hosts that never gained the
# webapp). Needs jq; `column` from util-linux for alignment (falls back
# to raw TSV if absent).
set -euo pipefail

EUROPA_HOST=${EUROPA_HOST:-root@10.1.1.2}
INVENTORY_PATH=${INVENTORY_PATH:-/tank/archive/retro/state/inventory.json}
ARCADE_WEBAPP_URL=${ARCADE_WEBAPP_URL:-http://10.1.1.2:8094}
ARCADE_STATUS_FALLBACK_SSH=${ARCADE_STATUS_FALLBACK_SSH:-1}

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required (nix shell nixpkgs#jq)" >&2
  exit 1
fi

doc=""
source_label=""
if url="${ARCADE_WEBAPP_URL%/}/inventory.json"; doc=$(curl -sf --max-time 10 "${url}" 2>/dev/null); then
  source_label="webapp ${ARCADE_WEBAPP_URL}"
elif [ "${ARCADE_STATUS_FALLBACK_SSH}" = "1" ]; then
  # Legacy transition path: the hourly unit's last written state file.
  doc=$(ssh "${EUROPA_HOST}" "cat '${INVENTORY_PATH}'" 2>/dev/null) || true
  source_label="legacy ${INVENTORY_PATH} on ${EUROPA_HOST} (SSH)"
fi

if [ -z "${doc}" ]; then
  echo "error: no inventory — webapp unreachable at ${ARCADE_WEBAPP_URL}" >&2
  [ "${ARCADE_STATUS_FALLBACK_SSH}" = "1" ] || true
  echo "error: and the SSH fallback (${INVENTORY_PATH} on ${EUROPA_HOST}) yielded nothing" >&2
  exit 1
fi

# Header: when it was generated + where this document came from + the
# rom-acquire download unit state.
generated_at=$(printf '%s' "${doc}" | jq -r '.generated_at // "unknown"')
rom_state=$(printf '%s' "${doc}" | jq -r '.rom_acquire.active_state // "unknown"')
echo "# jupiter arcade inventory  (generated ${generated_at} via ${source_label}; rom-acquire: ${rom_state})"
echo

table=$(
  printf '%s' "${doc}" | jq -r '
    def human:
      if . == null then "—"
      elif . >= 1073741824 then "\(((. / 1073741824 * 10) | floor) / 10)GiB"
      elif . >= 1048576    then "\(((. / 1048576 * 10) | floor) / 10)MiB"
      elif . >= 1024       then "\((. / 1024) | floor)KiB"
      else                      "\(.)B"
      end;

    (["SYSTEM", "ROMS", "SIZE", "ART%"] | @tsv),
    (["— cartridge —", "", "", ""] | @tsv),
    (.cartridge // {} | to_entries[]
      | [ .key,
          (.value.count | tostring),
          ((.value.size_bytes // 0) | human),
          "—"
        ] | @tsv),
    (["— optical —", "", "", ""] | @tsv),
    (.optical // {} | to_entries[]
      | [ .key,
          (.value.count | tostring),
          ((.value.size_bytes // 0) | human),
          "—"
        ] | @tsv),
    (["— modern —", "", "", ""] | @tsv),
    (.modern // {} | to_entries[]
      | [ .key,
          (.value.count | tostring),
          ((.value.size_bytes // 0) | human),
          "—"
        ] | @tsv),
    (["— eXo curated —", "", "", ""] | @tsv),
    (.exo // {} | to_entries[]
      | [ .key,
          (.value.games | tostring),
          "—",
          "\(.value.coverage_pct)%"
        ] | @tsv)
  '
)

if command -v column >/dev/null 2>&1; then
  printf '%s\n' "${table}" | column -t -s $'\t'
else
  printf '%s\n' "${table}"
fi
