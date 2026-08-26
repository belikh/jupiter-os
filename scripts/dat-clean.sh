#!/usr/bin/env bash
# dat-clean.sh - prune the promoted game trees on europa down to exactly what
# the No-Intro/Redump DATs describe, using igir's `clean` command.
#
# Why this exists: promotion (cartridge-verify.sh, now scripts/deprecated/;
# the webapp's igir runner does this today) moves DAT-matching ROMs into
# games/{cartridge,optical,modern}/<sys>, but the curated trees can still
# accumulate files the DATs don't know about - ROMs promoted as-is during the
# "missing DAT" degrade, hacks/translations a 1G1R DAT never intended, or
# corrupt leftovers. This pass removes those so the kiosk collections stay
# exactly the McLean 1G1R sets.
#
# SAFETY: this NEVER hard-deletes. Unknown files are MOVED to
# $CLEAN_BACKUP_DIR/<sys>/ (via igir --clean-backup) so a false positive is
# recoverable. `--clean-dry-run` (the default) only prints what would be
# removed; pass `--apply` to actually move them.
#
# Usage:
#   dat-clean.sh [--apply] [<root> ...]
#     root    ROM tree root to clean (default: the three bucket roots)
#
# Env:
#   DAT_DIR           No-Intro/Redump DATs, one <sys>.dat per system
#                     (default: /tank/archive/retro/metadata/no-intro-dats)
#   IGIR              igir binary (default: PATH lookup)
#   CLEAN_BACKUP_DIR  holding dir for removed files
#                     (default: /tank/archive/retro/scratch/dat-clean)
#
# Only <root>/<sys> dirs with a matching <DAT_DIR>/<sys>.dat are processed (no
# DAT -> cannot verify -> left alone). Non-ROM files (Pegasus metadata, media/
# artwork, .m3u playlists, Skyscraper leftovers) are excluded so clean can
# never touch them. NOTE: igir's --clean-exclude globs are resolved against
# the paths igir sees (i.e. CWD-relative), so this script passes absolute
# exclude paths; run it from any CWD.
#
# Run only while no rom-verify is actively writing into these trees.

set -uo pipefail

DAT_DIR="${DAT_DIR:-/tank/archive/retro/metadata/no-intro-dats}"
IGIR="${IGIR:-igir}"
CLEAN_BACKUP_DIR="${CLEAN_BACKUP_DIR:-/tank/archive/retro/scratch/dat-clean}"

DEFAULT_ROOTS=(
  /tank/archive/retro/games/cartridge
  /tank/archive/retro/games/optical
  /tank/archive/retro/games/modern
)

APPLY=0
ROOTS=()
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    -h | --help)
      sed -n '2,26p' "$0"
      exit 0
      ;;
    *) ROOTS+=("$a") ;;
  esac
done
[ "${#ROOTS[@]}" -eq 0 ] && ROOTS=("${DEFAULT_ROOTS[@]}")

log() { printf '[dat-clean] %s\n' "$*" >&2; }

rc=0
for root in "${ROOTS[@]}"; do
  if [ ! -d "$root" ]; then
    log "root missing, skipping: $root"
    continue
  fi
  for sysdir in "$root"/*/; do
    [ -d "$sysdir" ] || continue
    sys=$(basename "$sysdir")
    dat="$DAT_DIR/$sys.dat"
    if [ ! -f "$dat" ]; then
      log "$sys: no DAT (${dat##*/}), leaving alone"
      continue
    fi
    log "cleaning $root/$sys against $(basename "$dat")"

    # Excludes must be absolute (igir resolves --clean-exclude against the
    # paths it operates on). Patterns cover the Pegasus artwork tree, the
    # Pegasus metadata file, Skyscraper leftovers, and multi-disc playlists.
    clean_args=(
      move
      clean
      --dat "$dat"
      --input "$root/$sys"
      --output "$root/$sys"
      --input-checksum-max CRC32
      --clean-exclude "$root/$sys/media/**"
      --clean-exclude "$root/$sys/metadata.pegasus.txt"
      --clean-exclude "$root/$sys/**/~~.skyscraper~*"
      --clean-exclude "$root/$sys/**/*.m3u"
    )
    if [ "$APPLY" -eq 1 ]; then
      mkdir -p "$CLEAN_BACKUP_DIR/$sys"
      clean_args+=(--clean-backup "$CLEAN_BACKUP_DIR/$sys")
      log "  --apply: moving unknowns to $CLEAN_BACKUP_DIR/$sys"
    else
      clean_args+=(--clean-dry-run)
      log "  dry run (no files moved); re-run with --apply to remove"
    fi

    if ! "$IGIR" "${clean_args[@]}"; then
      log "$sys: igir clean failed (rc=$?)"
      rc=1
    fi
  done
done

exit "$rc"