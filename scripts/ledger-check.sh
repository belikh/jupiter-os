#!/usr/bin/env bash
#
# ledger-check.sh — CI gate for the arcade remediation ledger
# (docs/plans/arcade-remediation-ledger.tsv; see SPEC.md constitution
# rule 3: "deferrals are dated ledger rows, never prose").
#
# The ledger is a TSV with one header row and columns:
#   id  kind  item  date_opened  trigger_date  status  note
#
#   kind    deferral | adoption | decommission
#   status  open     | done     | superseded (row replaced by another row,
#           which must be named in the note)
#
# Gate semantics — a row's trigger_date is a commitment to REVISIT, not a
# deadline to ship: when the date arrives with the row still open, this
# script FAILS (the CI reminder) until the row is triaged — resolved,
# re-dated with a written reason in the note, or marked superseded.
# Deleting a due row to go green is exactly the "prose deferral" the
# constitution forbids; keep the audit trail and re-date with a reason.
#
# Malformed rows (wrong field count, bad dates, duplicate ids, trigger
# before the row was opened) also fail — a ledger CI cannot parse is
# indistinguishable from no ledger.
#
# Usage: scripts/ledger-check.sh [ledger.tsv]
#        (default: docs/plans/arcade-remediation-ledger.tsv from repo root)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEDGER="${1:-$REPO_ROOT/docs/plans/arcade-remediation-ledger.tsv}"
TODAY="$(date -u +%Y-%m-%d)"

[ -f "$LEDGER" ] || { echo "ledger-check: no ledger at $LEDGER" >&2; exit 1; }

errors=0
row=0
seen_ids=""

# Validate one ISO date (and echo it back normalised).
valid_date() {
  date -u -d "$1" +%Y-%m-%d >/dev/null 2>&1 || return 1
  # Reject things GNU date accepts but the ledger never means, e.g. "2026-8-1".
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
}

while IFS=$'\t' read -r id kind item opened trigger status note; do
  row=$((row + 1))

  # Header + blanks/comments.
  case "$id" in
    id) continue ;;
    ""|\#*) continue ;;
  esac

  # Field count: read with IFS=tab yields 7 fields; empties are allowed in
  # note only. A short line pads the tail with empty strings — detect via
  # the raw line itself.
  raw="$(sed -n "${row}p" "$LEDGER")"
  nf=$(awk -F'\t' '{print NF}' <<<"$raw")
  if [ "$nf" -ne 7 ]; then
    echo "ledger-check: line $row: expected 7 tab-separated fields, got $nf: $raw" >&2
    errors=$((errors + 1))
    continue
  fi

  # Duplicate ids break the audit trail's referencability.
  if grep -qxF "$id" <<<"$seen_ids"; then
    echo "ledger-check: line $row: duplicate id '$id'" >&2
    errors=$((errors + 1))
  fi
  seen_ids+="$id"$'\n'

  # Enumerations.
  case "$kind" in
    deferral|adoption|decommission) ;;
    *) echo "ledger-check: line $row ($id): bad kind '$kind' (want deferral|adoption|decommission)" >&2; errors=$((errors + 1)) ;;
  esac
  case "$status" in
    open|done|superseded) ;;
    *) echo "ledger-check: line $row ($id): bad status '$status' (want open|done|superseded)" >&2; errors=$((errors + 1)) ;;
  esac

  # Dates.
  if ! valid_date "$opened"; then
    echo "ledger-check: line $row ($id): bad date_opened '$opened'" >&2
    errors=$((errors + 1))
  fi
  if ! valid_date "$trigger"; then
    echo "ledger-check: line $row ($id): bad trigger_date '$trigger'" >&2
    errors=$((errors + 1))
    continue
  fi
  if [ "$(date -u -d "$trigger" +%s)" -lt "$(date -u -d "$opened" +%s)" ]; then
    echo "ledger-check: line $row ($id): trigger_date $trigger precedes date_opened $opened" >&2
    errors=$((errors + 1))
  fi

  # The reminder: a due or overdue open row fails the gate until triaged.
  if [ "$status" = "open" ] && [[ "$trigger" < "$TODAY" || "$trigger" == "$TODAY" ]]; then
    echo "ledger-check: DUE ($id): '$item' (trigger $trigger) is open — resolve it, or re-date with a written reason in its note. Deleting the row to go green is the prose deferral the constitution forbids." >&2
    errors=$((errors + 1))
  fi
done < "$LEDGER"

if [ "$row" -eq 0 ]; then
  echo "ledger-check: ledger $LEDGER has no rows" >&2
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo "ledger-check: FAILED ($errors problem(s))" >&2
  exit 1
fi

echo "ledger-check: OK ($(grep -c . "$LEDGER") lines, no due open rows, all rows well-formed)"
