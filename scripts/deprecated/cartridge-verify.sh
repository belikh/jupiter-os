#!/usr/bin/env bash
# cartridge-verify.sh - verify No-Intro cartridge ROM sets against their DATs
# and copy the verified ROMs into the curated games tree (igir, https://igir.io).
# Run on europa against the aria2-staged Minerva/Myrient No-Intro trees.
#
# Usage: cartridge-verify.sh [system ...]
#   system   short system keys to process (default: nes snes gb gbc gba n64)
#
# Env (all optional, with europa on-pool defaults):
#   INCOMING_DIR    staged aria2 download roots, one <sys>/ subdir each
#   DAT_DIR         No-Intro .dat files, one per system: <sys>.dat
#   CARTRIDGE_DIR   verified-playable destination tree, one <sys>/ subdir each
#   SCRATCH_DIR     audit reports (reports/) land here
#   IGIR            igir binary  (default: PATH lookup)
#   RSYNC           rsync binary (default: PATH lookup)
#
# Per system:
#   * Nothing staged under <INCOMING_DIR>/<sys>  -> skip (idempotent).
#   * No <DAT_DIR>/<sys>.dat                     -> warn, skip verification,
#     and copy everything staged straight to <CARTRIDGE_DIR>/<sys>/ (better
#     partial than blocked).
#   * Otherwise: igir `copy test report` hashes every staged file against the
#     DAT in a single pass and COPIES the DAT-matched, checksum-valid ROMs into
#     <CARTRIDGE_DIR>/<sys>/, writing an audit CSV to
#     <SCRATCH_DIR>/reports/<sys>.csv.
#
# Design notes (deliberate):
#   * COPY, never move/link/quarantine. The staged tree IS the aria2 torrent
#     download; moving verified ROMs out of it breaks the daemon's piece state
#     and forces a re-download loop on resume, and quarantining unmatched files
#     filled the 500G scratch quota (EDQUOT) for zero benefit - the DAT is
#     authoritative and unmatched files are deliberately excluded from a 1G1R
#     collection. Copying leaves the torrent tree fully intact: aria2 keeps all
#     pieces, unmatched files just stay in the download dir, and the games tree
#     is a pure curated view. (games/ and cache/ are separate ZFS datasets, so
#     igir hardlink/reflink cannot span them; symlinks would dangle unless the
#     kiosk also mounts cache.)
#   * Re-runs are safe: copying over an already-promoted canonical name is a
#     no-op, and an empty staged tree is skipped.
#
# A system whose staged tree still holds aria2 control files (*.aria2) is
# SKIPPED entirely: the control files are aria2's resume state and the
# partial/preallocated ROM files cannot DAT-match, so verifying a mid-download
# system would flood the games tree with junk.

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
mkdir -p "$REPORT_DIR"

log()  { printf '[cartridge-verify] %s\n' "$*" >&2; }
warn() { printf '[cartridge-verify] WARNING: %s\n' "$*" >&2; }

# process_system runs in a subshell so a hard failure (set -e) on one system
# is reported and skipped without aborting the whole run.
process_system() (
  local sys="$1"
  local incoming="$INCOMING_DIR/$sys"
  local dat="$DAT_DIR/$sys.dat"
  local cartridge="$CARTRIDGE_DIR/$sys"
  local report="$REPORT_DIR/$sys.csv"

  if [ ! -d "$incoming" ] \
     || [ -z "$(find "$incoming" -type f -print -quit)" ]; then
    log "$sys: nothing staged, skipping"
    exit 0
  fi

  # Download still in flight? The .aria2 control files are aria2's resume
  # state, and the partial files cannot DAT-match — copying now would flood
  # the games tree with junk.
  if [ -n "$(find "$incoming" -name '*.aria2' -print -quit 2>/dev/null)" ]; then
    log "$sys: still downloading (aria2 control files present), skipping"
    exit 0
  fi

  mkdir -p "$cartridge"

  if [ ! -f "$dat" ]; then
    warn "$sys: missing DAT ($dat) - skipping verification, copying staged ROMs as-is"
    "$RSYNC" -a "$incoming/" "$cartridge/"
    log "$sys: copied (unverified) to $cartridge"
    exit 0
  fi

  log "$sys: verifying staged files against $dat"
  # `copy test report` (https://igir.io/commands/): copy writes DAT-matched
  # ROMs to the output dir, leaving the staged/torrent tree fully intact;
  # test re-checks each written file's size+checksum; report emits the audit
  # CSV. --dir-game-subdir never keeps single-ROM cartridge games flat.
  if ! "$IGIR" copy test report \
        --dat "$dat" \
        --input "$incoming" \
        --output "$cartridge" \
        --report-output "$report" \
        --input-checksum-max CRC32 \
        --dir-game-subdir never \
        --reader-threads 2 \
        --writer-threads 2 \
        --dat-threads 1; then
    warn "$sys: igir exited non-zero; see $report"
  fi

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