#!/usr/bin/env bash
# fixture-arcade.sh - regenerate the arcade-webapp fixture ROM tree and run
# the igir zero-unmatched gate over it (gauntlet plan §1.3 item 6 / AC-3's
# fixture half).
#
# The corpus is fully self-authored: three Logiqx DATs committed at
# pkgs/arcade-webapp/testdata/dats/ describe dummy ROMs whose bytes are a
# deterministic SHA-256 stream keyed by system+filename (see
# pkgs/arcade-webapp/internal/fixture), so nothing copyrighted ever enters
# the repo and the DATs stay valid across regenerations.
#
# Usage: make fixture-arcade   (or scripts/fixture-arcade.sh directly)
# Env (optional):
#   FIXTURE_ROOT   where the tree materializes
#                  (default: <repo>/tests/fixtures/arcade)
#   IGIR           igir invocation (default: nix run pinned to the flake's
#                  locked nixpkgs — no channel drift)
#
# Gate (exits non-zero on any failure):
#   * `igir copy test report` per system with the exact flag set of
#     scripts/cartridge-verify.sh (the pipeline this fixture models);
#   * every DAT game FOUND (matched + written + checksum-retested);
#   * zero UNUSED rows in the report CSV (= zero unmatched input files).
#   igir's report CSV has no quoting needs here: fixture names are
#   comma-free (enforced by TestNamesWellFormed), so a plain comma split is
#   safe and field 3 is always Status.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_ROOT="${FIXTURE_ROOT:-$REPO_ROOT/tests/fixtures/arcade}"
DAT_DIR="$REPO_ROOT/pkgs/arcade-webapp/testdata/dats"
IGIR="${IGIR:-nix run --inputs-from $REPO_ROOT nixpkgs#igir --}"

INCOMING="$FIXTURE_ROOT/incoming"
VERIFIED="$FIXTURE_ROOT/verified"
REPORTS="$FIXTURE_ROOT/reports"

log()  { printf '[fixture-arcade] %s\n' "$*" >&2; }

# 1. Regenerate the deterministic ROM tree (byte-identical every run). The
#    tree is disposable generated output, so wipe it first — a corrupted or
#    half-written file must never wedge the gate. Drift between the
#    generator and the COMMITTED DATs is caught separately (and airtight) by
#    TestRomsMatchCommittedDATs in pkgs/arcade-webapp.
log "generating fixture ROM tree under $INCOMING"
rm -rf "$INCOMING" "$VERIFIED" "$REPORTS"
( cd "$REPO_ROOT/pkgs/arcade-webapp" && go run ./cmd/fixturegen --roms "$INCOMING" )

# 2. Per-system igir gate. process_system runs in a subshell so a hard
#    failure on one system is reported and skipped without aborting the
#    whole run (cartridge-verify.sh pattern).
process_system() (
  local sys="$1"
  local dat="$DAT_DIR/$sys.dat"
  local incoming="$INCOMING/$sys"
  local cartridge="$VERIFIED/$sys"
  local report="$REPORTS/$sys.csv"

  [ -f "$dat" ] || { log "$sys: missing DAT $dat"; exit 1; }

  mkdir -p "$cartridge" "$REPORTS"

  log "$sys: igir copy test report against $dat"
  # Same combination and flags as cartridge-verify.sh: copy writes DAT-matched
  # ROMs to the output dir, test re-checks each written file's size+checksum,
  # report emits the audit CSV. --dir-game-subdir never keeps single-ROM
  # cartridge games flat; CRC32-max input hashing matches the HDD-friendly
  # production setting.
  $IGIR copy test report \
        --dat "$dat" \
        --input "$incoming" \
        --output "$cartridge" \
        --report-output "$report" \
        --input-checksum-max CRC32 \
        --dir-game-subdir never \
        --reader-threads 2 \
        --writer-threads 2 \
        --dat-threads 1

  # 3. Zero-unmatched assertion off the report CSV: field 3 is Status
  #    (FOUND = DAT game matched+written; UNUSED = input file no DAT
  #    claims; anything else — MISSING, error states — also fails).
  local games found unused other
  games=$(grep -c '<game ' "$dat" || true)
  found=$(awk -F, 'NR>1 && $3=="FOUND"' "$report" | wc -l)
  unused=$(awk -F, 'NR>1 && $3=="UNUSED"' "$report" | wc -l)
  other=$(awk -F, 'NR>1 && $3!="" && $3!="FOUND" && $3!="UNUSED"' "$report" | wc -l)

  if [ "$found" -ne "$games" ] || [ "$unused" -ne 0 ] || [ "$other" -ne 0 ]; then
    log "$sys: FAIL — found=$found/$games unmatched=$unused other=$other (report: $report)"
    exit 1
  fi
  log "$sys: PASS — $found/$games games found, 0 unmatched"
)

rc=0
for sys in nes snes gb; do
  if ! process_system "$sys"; then
    log "$sys: gate failed"
    rc=1
  fi
done

if [ "$rc" -ne 0 ]; then
  log "GATE: FAIL"
  exit "$rc"
fi
log "GATE: PASS — fixture tree igir-verified with zero unmatched"
