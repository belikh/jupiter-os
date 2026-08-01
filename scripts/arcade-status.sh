#!/usr/bin/env bash
# arcade-status.sh — dev convenience: pull europa's arcade inventory and
# pretty-print a one-screen table. Intended for `make status-arcade`.
#
#   ./scripts/arcade-status.sh
#   EUROPA_HOST=root@10.1.1.2 INVENTORY_PATH=/tank/archive/retro/state/inventory.json \
#     ./scripts/arcade-status.sh
#
# Reads the JSON that jupiter-arcade-inventory.service writes on europa over
# SSH (no daemon to talk to). Needs jq on the local machine; `column` from
# util-linux for alignment (falls back to raw TSV if absent).
set -euo pipefail

EUROPA_HOST=${EUROPA_HOST:-root@10.1.1.2}
INVENTORY_PATH=${INVENTORY_PATH:-/tank/archive/retro/state/inventory.json}

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required (nix shell nixpkgs#jq)" >&2
  exit 1
fi

# Cat the remote inventory; let SSH errors propagate.
doc=$(ssh "${EUROPA_HOST}" "cat '${INVENTORY_PATH}'" 2>/dev/null) || {
  echo "error: could not read ${INVENTORY_PATH} on ${EUROPA_HOST}" >&2
  exit 1
}

if [ -z "${doc}" ]; then
  echo "inventory empty or missing — has jupiter-arcade-inventory.timer fired yet?" >&2
  exit 1
fi

# Header: when it was generated + the rom-acquire download unit state.
generated_at=$(printf '%s' "${doc}" | jq -r '.generated_at // "unknown"')
rom_state=$(printf '%s' "${doc}" | jq -r '.rom_acquire.active_state // "unknown"')
echo "# jupiter arcade inventory  (generated ${generated_at}, rom-acquire: ${rom_state})"
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
