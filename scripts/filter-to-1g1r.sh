#!/usr/bin/env bash
# filter-to-1g1r.sh — Move destination ROMs back to cache, re-verify with 1G1R DATs
# Result: only McLean 1G1R games remain in /tank/archive/retro/games/<bucket>/
#
# SAFETY (W1-T4): destructive by design — Step 1/2 hard-DELETE every file
# left in the promoted destination trees after moving DAT-verified ROMs back
# to the incoming cache, and Steps 3/4 DELETE or quarantine every incoming
# file igir already promoted. The default is therefore a DRY RUN that only
# prints what would happen; pass `--apply` to actually move/delete (the
# sibling dat-clean.sh's grammar, ported here). Never run concurrently with
# a rom-verify pass writing into the same trees.
#
# W1-T4 bugfix: Step 3 previously aborted on the first system (`local`
# outside a function is a hard error under `set -e`), so re-verification
# never actually ran.
#
# Usage:
#   filter-to-1g1r.sh [--apply]
#
# Env:
#   DAT_DIR         1G1R DATs, one <sys>.dat per system
#                   (default: /tank/archive/retro/metadata/no-intro-dats)
#   INCOMING_ROOT   cache tree the ROMs are moved back into
#                   (default: /tank/archive/retro/cache/incoming/nointro-nintendo)
#   CART_ROOT       cartridge bucket root   (default: .../games/cartridge)
#   OPTICAL_ROOT    optical bucket root     (default: .../games/optical)
#   MODERN_ROOT     modern bucket root      (default: .../games/modern)
#   SCRATCH_DIR     reports + quarantine    (default: /tank/archive/retro/scratch)
#   IGIR            igir binary (default: PATH lookup)
#   RSYNC           rsync binary (default: PATH lookup; currently unused)

set -euo pipefail

DAT_DIR="${DAT_DIR:-/tank/archive/retro/metadata/no-intro-dats}"
INCOMING_ROOT="${INCOMING_ROOT:-/tank/archive/retro/cache/incoming/nointro-nintendo}"
CART_ROOT="${CART_ROOT:-/tank/archive/retro/games/cartridge}"
OPTICAL_ROOT="${OPTICAL_ROOT:-/tank/archive/retro/games/optical}"
MODERN_ROOT="${MODERN_ROOT:-/tank/archive/retro/games/modern}"
SCRATCH_DIR="${SCRATCH_DIR:-/tank/archive/retro/scratch}"
REPORT_DIR="$SCRATCH_DIR/reports"
QUARANTINE_BASE="$SCRATCH_DIR/quarantine"

IGIR="${IGIR:-igir}"
RSYNC="${RSYNC:-rsync}"

APPLY=0
for a in "$@"; do
    case "$a" in
        --apply) APPLY=1 ;;
        -h | --help)
            sed -n '2,36p' "$0"
            exit 0
            ;;
        *)
            echo "filter-to-1g1r: unknown argument: $a (usage: $0 [--apply])" >&2
            exit 2
            ;;
    esac
done

log() { printf '[filter-to-1g1r] %s\n' "$*" >&2; }

# Mutation gates — everything that moves or deletes a file goes through
# these, so a dry run provably changes nothing.
do_mv() { # do_mv <src> <dst>
    if [ "$APPLY" -eq 1 ]; then
        mv -f -- "$1" "$2"
    else
        echo "    dry-run: mv '$1' -> '$2'"
    fi
}

do_rmtree() { # do_rmtree <dir> — delete files, then empty dirs
    if [ "$APPLY" -eq 1 ]; then
        find "$1" -type f -delete 2>/dev/null
        find "$1" -depth -type d -empty -delete 2>/dev/null || true
    else
        echo "    dry-run: delete all files + empty dirs under '$1'"
    fi
}

do_igir() { # do_igir <dat> <input> <output> <report>
    if [ "$APPLY" -eq 1 ]; then
        "$IGIR" move test report \
            --dat "$1" \
            --input "$2" \
            --output "$3" \
            --report-output "$4" \
            --dir-game-subdir never 2>&1 | tail -5
    else
        echo "    dry-run: $IGIR move test report --dat '$1' --input '$2' --output '$3' --report-output '$4' --dir-game-subdir never"
    fi
}

# Systems already verified with 1G1R DATs (from journalctl)
CARTRIDGE_DONE=(dsi fds gameandwatch gb gba gbc n64)

# Systems still processing or not started (documentation of remaining work;
# Step 3 intentionally re-verifies only CARTRIDGE_DONE — shellcheck SC2034)
# shellcheck disable=SC2034
CARTRIDGE_REMAINING=(nds nes pokemonmini snes virtualboy)

if [ "$APPLY" -eq 0 ]; then
    log "DRY RUN (default) — nothing is moved or deleted; re-run with --apply"
else
    log "--apply: mutations enabled"
fi

echo "=== Step 1: Move 1G1R-verified cartridge ROMs back to cache ==="
for sys in "${CARTRIDGE_DONE[@]}"; do
    report="$REPORT_DIR/$sys.csv"
    dest_dir="$CART_ROOT/$sys"
    incoming_dir="$INCOMING_ROOT/$sys"

    if [[ ! -f "$report" ]]; then
        echo "  $sys: No report found, skipping"
        continue
    fi

    echo "  $sys: Processing..."
    if [ "$APPLY" -eq 1 ]; then
        mkdir -p "$incoming_dir"
    else
        echo "    dry-run: mkdir -p '$incoming_dir'"
    fi

    # Extract FOUND ROM paths from CSV (column 4), move them back to incoming
    # CSV format: DAT Name,Game Name,Status,ROM Files,...
    tail -n +2 "$report" | awk -F',' '$3 == "FOUND" {print $4}' | sed 's/^"//;s/"$//' | while IFS= read -r rom_path; do
        if [[ -f "$rom_path" ]]; then
            filename=$(basename "$rom_path")
            do_mv "$rom_path" "$incoming_dir/$filename"
        fi
    done

    # Remove any remaining files in dest (non-1G1R)
    do_rmtree "$dest_dir"

    echo "    $(find "$incoming_dir" -type f 2>/dev/null | wc -l) files in incoming cache"
done

echo ""
echo "=== Step 2: Clean optical/modern destinations (will re-verify) ==="
# GameCube already verified with Redump 1G1R
report="$REPORT_DIR/gamecube.csv"
if [[ -f "$report" ]]; then
    incoming_dir="$INCOMING_ROOT/gamecube"
    dest_dir="$OPTICAL_ROOT/gamecube"
    if [ "$APPLY" -eq 1 ]; then
        mkdir -p "$incoming_dir"
    else
        echo "    dry-run: mkdir -p '$incoming_dir'"
    fi
    tail -n +2 "$report" | awk -F',' '$3 == "FOUND" {print $4}' | sed 's/^"//;s/"$//' | while IFS= read -r rom_path; do
        if [[ -f "$rom_path" ]]; then
            filename=$(basename "$rom_path")
            do_mv "$rom_path" "$incoming_dir/$filename"
        fi
    done
    do_rmtree "$dest_dir"
    echo "  gamecube: $(find "$incoming_dir" -type f 2>/dev/null | wc -l) files in incoming cache"
fi

# Clean other optical/modern dirs (will be populated when downloads complete)
for bucket_root in "$OPTICAL_ROOT" "$MODERN_ROOT"; do
    for sys_dir in "$bucket_root"/*/; do
        [ -d "$sys_dir" ] || continue
        do_rmtree "${sys_dir%/}"
    done
done

echo ""
echo "=== Step 3: Re-run verification for cartridge systems ==="
for sys in "${CARTRIDGE_DONE[@]}"; do
    incoming="$INCOMING_ROOT/$sys"
    dat="$DAT_DIR/$sys.dat"
    cartridge="$CART_ROOT/$sys"
    quarantine="$QUARANTINE_BASE/$sys"
    report="$REPORT_DIR/$sys.csv"

    if [[ ! -d "$incoming" ]] || [[ -z "$(find "$incoming" -type f -print -quit)" ]]; then
        echo "  $sys: No files in incoming, skipping"
        continue
    fi
    if [[ ! -f "$dat" ]]; then
        echo "  $sys: No DAT found, skipping"
        continue
    fi

    echo "  $sys: Re-verifying with 1G1R DAT..."
    if [ "$APPLY" -eq 1 ]; then
        mkdir -p "$cartridge" "$quarantine"
    else
        echo "    dry-run: mkdir -p '$cartridge' '$quarantine'"
    fi

    do_igir "$dat" "$incoming" "$cartridge" "$report"

    # Quarantine leftovers
    qcount=0
    while IFS= read -r -d '' f; do
        [[ "$f" == *.aria2 ]] && continue
        rel="${f#"$incoming"/}"
        base=$(basename -- "$f")
        if [[ -e "$cartridge/$rel" ]] || [[ -e "$cartridge/$base" ]] || [[ -n "$(find "$cartridge" -type f -name "$base" -print -quit 2>/dev/null)" ]]; then
            if [ "$APPLY" -eq 1 ]; then
                rm -f -- "$f"
            else
                echo "    dry-run: rm '$f'"
            fi
        else
            if [ "$APPLY" -eq 1 ]; then
                mkdir -p "$quarantine/$(dirname "$rel")"
                mv -f -- "$f" "$quarantine/$rel"
            else
                echo "    dry-run: mv '$f' -> '$quarantine/$rel'"
            fi
            qcount=$((qcount + 1))
        fi
    done < <(find "$incoming" -type f -print0)

    if [ "$APPLY" -eq 1 ]; then
        find "$incoming" -depth -type d -empty -delete 2>/dev/null || true
    else
        echo "    dry-run: delete empty dirs under '$incoming'"
    fi
    echo "    Done: $(find "$cartridge" -type f 2>/dev/null | wc -l) files promoted, $qcount quarantined"
done

echo ""
echo "=== Step 4: Re-verify GameCube (Redump 1G1R) ==="
sys="gamecube"
incoming="$INCOMING_ROOT/$sys"
dat="$DAT_DIR/$sys.dat"
cartridge="$OPTICAL_ROOT/$sys"
quarantine="$QUARANTINE_BASE/$sys"
report="$REPORT_DIR/$sys.csv"

if [[ -d "$incoming" ]] && [[ -n "$(find "$incoming" -type f -print -quit)" ]] && [[ -f "$dat" ]]; then
    echo "  $sys: Re-verifying with Redump 1G1R DAT..."
    if [ "$APPLY" -eq 1 ]; then
        mkdir -p "$cartridge" "$quarantine"
    else
        echo "    dry-run: mkdir -p '$cartridge' '$quarantine'"
    fi
    do_igir "$dat" "$incoming" "$cartridge" "$report"

    qcount=0
    while IFS= read -r -d '' f; do
        [[ "$f" == *.aria2 ]] && continue
        rel="${f#"$incoming"/}"
        base=$(basename -- "$f")
        if [[ -e "$cartridge/$rel" ]] || [[ -e "$cartridge/$base" ]] || [[ -n "$(find "$cartridge" -type f -name "$base" -print -quit 2>/dev/null)" ]]; then
            if [ "$APPLY" -eq 1 ]; then
                rm -f -- "$f"
            else
                echo "    dry-run: rm '$f'"
            fi
        else
            if [ "$APPLY" -eq 1 ]; then
                mkdir -p "$quarantine/$(dirname "$rel")"
                mv -f -- "$f" "$quarantine/$rel"
            else
                echo "    dry-run: mv '$f' -> '$quarantine/$rel'"
            fi
            qcount=$((qcount + 1))
        fi
    done < <(find "$incoming" -type f -print0)
    if [ "$APPLY" -eq 1 ]; then
        find "$incoming" -depth -type d -empty -delete 2>/dev/null || true
    else
        echo "    dry-run: delete empty dirs under '$incoming'"
    fi
    echo "    Done: $(find "$cartridge" -type f 2>/dev/null | wc -l) files promoted, $qcount quarantined"
fi

echo ""
echo "=== Complete ==="
echo "Cartridge bucket:"
for d in "$CART_ROOT"/*/; do
    [ -d "$d" ] || continue
    count=$(find "$d" -type f -name "*.zip" 2>/dev/null | wc -l)
    echo "  $(basename "$d"): $count"
done
echo "Optical bucket:"
for d in "$OPTICAL_ROOT"/*/; do
    [ -d "$d" ] || continue
    count=$(find "$d" -type f 2>/dev/null | wc -l)
    echo "  $(basename "$d"): $count"
done
