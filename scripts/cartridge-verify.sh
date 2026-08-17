#!/usr/bin/env bash
# cartridge-verify.sh - verify, quarantine, and promote No-Intro cartridge
# ROM sets using igir (https://igir.io). Run on europa against the aria2-staged
# Minerva/Myrient No-Intro Nintendo trees.
#
# Usage: cartridge-verify.sh [system ...]
#   system   short system keys to process (default: nes snes gb gbc gba n64)
#
# Env (all optional, with europa on-pool defaults):
#   INCOMING_DIR    staged aria2 download roots, one <sys>/ subdir each
#   DAT_DIR         No-Intro .dat files, one per system: <sys>.dat
#   CARTRIDGE_DIR   verified-playable destination tree, one <sys>/ subdir each
#   SCRATCH_DIR     audit reports (reports/) + quarantine (quarantine/) land here
#   IGIR            igir binary  (default: PATH lookup)
#   RSYNC           rsync binary (default: PATH lookup)
#
# Per system:
#   * Nothing staged under <INCOMING_DIR>/<sys>            -> skip (idempotent).
#   * No <DAT_DIR>/<sys>.dat                                -> warn, skip
#     verification, and promote everything staged straight to
#     <CARTRIDGE_DIR>/<sys>/ (better partial than blocked).
#   * Otherwise: igir `move test report` hashes every staged file against the
#     DAT in a single pass. DAT-matched, checksum-valid ROMs are MOVED into
#     <CARTRIDGE_DIR>/<sys>/ (source removed only after a verified write), and
#     an audit CSV is written to <SCRATCH_DIR>/reports/<sys>.csv. Files that
#     did not match any DAT ROM (corrupt / junk / mis-named) stay staged and
#     are then moved to <SCRATCH_DIR>/quarantine/<sys>/.
#
# Idempotent + safe to re-run: an empty staged tree is a no-op, and a re-run
# that re-stages a ROM already present in the cartridge tree (same canonical
# No-Intro name) just deletes the duplicate instead of re-quarantining it.
#
# A system whose staged tree still holds aria2 control files (*.aria2) is
# SKIPPED entirely: the control files are aria2's resume state and the
# partial/preallocated ROM files cannot DAT-match, so processing a
# mid-download system would quarantine both and destroy the download's
# progress.

set -euo pipefail

INCOMING_DIR="${INCOMING_DIR:-/tank/archive/retro/cache/incoming/nointro-nintendo}"
DAT_DIR="${DAT_DIR:-/tank/archive/retro/metadata/no-intro-dats}"
CARTRIDGE_DIR="${CARTRIDGE_DIR:-/tank/archive/retro/games/cartridge}"
SCRATCH_DIR="${SCRATCH_DIR:-/tank/archive/retro/scratch}"
IGIR="${IGIR:-igir}"
RSYNC="${RSYNC:-rsync}"

if [ "$#" -gt 0 ]; then
  SYSTEMS=("$@")
else
  SYSTEMS=(nes snes gb gbc gba n64)
fi

REPORT_DIR="$SCRATCH_DIR/reports"
QUARANTINE_BASE="$SCRATCH_DIR/quarantine"
mkdir -p "$REPORT_DIR"

log()  { printf '[cartridge-verify] %s\n' "$*" >&2; }
warn() { printf '[cartridge-verify] WARNING: %s\n' "$*" >&2; }

# Move every regular file left staged for <sys> (i.e. not consumed by igir)
# into the quarantine tree. aria2 control files are never touched (they are
# resume state, not ROMs). A leftover already promoted on a previous run is
# deleted rather than duplicated under quarantine — igir writes promotions
# under the ROM's CANONICAL DAT name (flattened by --dir-game-subdir never),
# which usually differs from the staged Minerva_Myrient/... relative path, so
# the basename is checked under the cartridge tree (any depth) as well as the
# literal relative path. Echoes the count of files actually quarantined
# (duplicates deleted are not counted).
quarantine_leftovers() {
  local incoming="$1" cartridge="$2" quarantine="$3"
  mkdir -p "$quarantine"
  local qcount=0 f rel base
  while IFS= read -r -d '' f; do
    case "$f" in
      *.aria2) continue ;;
    esac
    rel="${f#"$incoming"/}"
    base=$(basename -- "$f")
    if [ -e "$cartridge/$rel" ] || [ -e "$cartridge/$base" ] \
       || [ -n "$(find "$cartridge" -type f -name "$base" -print -quit 2>/dev/null)" ]; then
      rm -f -- "$f"
      log "dropping already-promoted duplicate: $rel"
    else
      mkdir -p "$quarantine/$(dirname "$rel")"
      mv -f -- "$f" "$quarantine/$rel"
      qcount=$((qcount + 1))
    fi
  done < <(find "$incoming" -type f -print0)
  echo "$qcount"
}

# process_system runs in a subshell so a hard failure (set -e) on one system
# is reported and skipped without aborting the whole run.
process_system() (
  local sys="$1"
  local incoming="$INCOMING_DIR/$sys"
  local dat="$DAT_DIR/$sys.dat"
  local cartridge="$CARTRIDGE_DIR/$sys"
  local quarantine="$QUARANTINE_BASE/$sys"
  local report="$REPORT_DIR/$sys.csv"

  if [ ! -d "$incoming" ] \
     || [ -z "$(find "$incoming" -type f -print -quit)" ]; then
    log "$sys: nothing staged, skipping"
    exit 0
  fi

  # Download still in flight? The .aria2 control files are aria2's resume
  # state, and the partial files cannot DAT-match — verifying now would
  # quarantine both and destroy the download's progress.
  if [ -n "$(find "$incoming" -name '*.aria2' -print -quit 2>/dev/null)" ]; then
    log "$sys: still downloading (aria2 control files present), skipping"
    exit 0
  fi

  mkdir -p "$cartridge"

  if [ ! -f "$dat" ]; then
    warn "$sys: missing DAT ($dat) - skipping verification, promoting staged ROMs as-is"
    "$RSYNC" -a --remove-source-files "$incoming/" "$cartridge/"
    find "$incoming" -depth -type d -empty -delete 2>/dev/null || true
    log "$sys: promoted (unverified) to $cartridge"
    exit 0
  fi

  log "$sys: verifying staged files against $dat"
  # `move test report` (https://igir.io/commands/): move writes DAT-matched
  # ROMs to the output dir and removes the source only on a verified write;
  # test re-checks each written file's size+checksum; report emits the audit
  # CSV. --dir-game-subdir never keeps single-ROM cartridge games flat.
  if ! "$IGIR" move test report \
        --dat "$dat" \
        --input "$incoming" \
        --output "$cartridge" \
        --report-output "$report" \
        --dir-game-subdir never; then
    warn "$sys: igir exited non-zero; continuing to quarantine any unmatched staged files"
  fi

  local q
  q="$(quarantine_leftovers "$incoming" "$cartridge" "$quarantine")"
  if [ "$q" -gt 0 ]; then
    warn "$sys: quarantined $q unmatched file(s) to $quarantine (see $report)"
  fi
  find "$incoming" -depth -type d -empty -delete 2>/dev/null || true
  log "$sys: done (audit report: $report)"
)

rc=0
for sys in "${SYSTEMS[@]}"; do
  if ! process_system "$sys"; then
    warn "$sys: processing failed"
    rc=1
  fi
done

exit "$rc"
