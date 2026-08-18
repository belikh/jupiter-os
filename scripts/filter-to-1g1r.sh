#!/usr/bin/env bash
# filter-to-1g1r.sh — Move destination ROMs back to cache, re-verify with 1G1R DATs
# Result: only McLean 1G1R games remain in /tank/archive/retro/games/<bucket>/

set -euo pipefail

DAT_DIR="/tank/archive/retro/metadata/no-intro-dats"
INCOMING_ROOT="/tank/archive/retro/cache/incoming/nointro-nintendo"
CART_ROOT="/tank/archive/retro/games/cartridge"
OPTICAL_ROOT="/tank/archive/retro/games/optical"
MODERN_ROOT="/tank/archive/retro/games/modern"
SCRATCH_DIR="/tank/archive/retro/scratch"
REPORT_DIR="$SCRATCH_DIR/reports"
QUARANTINE_BASE="$SCRATCH_DIR/quarantine"

IGIR="${IGIR:-igir}"
RSYNC="${RSYNC:-rsync}"

# Systems already verified with 1G1R DATs (from journalctl)
CARTRIDGE_DONE=(dsi fds gameandwatch gb gba gbc n64)

# Systems still processing or not started
CARTRIDGE_REMAINING=(nds nes pokemonmini snes virtualboy)

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
    mkdir -p "$incoming_dir"
    
    # Extract FOUND ROM paths from CSV (column 4), move them back to incoming
    # CSV format: DAT Name,Game Name,Status,ROM Files,...
    tail -n +2 "$report" | awk -F',' '$3 == "FOUND" {print $4}' | sed 's/^"//;s/"$//' | while IFS= read -r rom_path; do
        if [[ -f "$rom_path" ]]; then
            filename=$(basename "$rom_path")
            mv -f "$rom_path" "$incoming_dir/$filename"
        fi
    done
    
    # Remove any remaining files in dest (non-1G1R)
    find "$dest_dir" -type f -delete 2>/dev/null
    find "$dest_dir" -depth -type d -empty -delete 2>/dev/null || true
    
    echo "    Moved $(find "$incoming_dir" -type f | wc -l) files back to cache"
done

echo ""
echo "=== Step 2: Clean optical/modern destinations (will re-verify) ==="
# GameCube already verified with Redump 1G1R
report="$REPORT_DIR/gamecube.csv"
if [[ -f "$report" ]]; then
    incoming_dir="$INCOMING_ROOT/gamecube"
    dest_dir="$OPTICAL_ROOT/gamecube"
    mkdir -p "$incoming_dir"
    tail -n +2 "$report" | awk -F',' '$3 == "FOUND" {print $4}' | sed 's/^"//;s/"$//' | while IFS= read -r rom_path; do
        if [[ -f "$rom_path" ]]; then
            filename=$(basename "$rom_path")
            mv -f "$rom_path" "$incoming_dir/$filename"
        fi
    done
    find "$dest_dir" -type f -delete 2>/dev/null
    find "$dest_dir" -depth -type d -empty -delete 2>/dev/null || true
    echo "  gamecube: Moved $(find "$incoming_dir" -type f | wc -l) files back to cache"
fi

# Clean other optical/modern dirs (will be populated when downloads complete)
for bucket_root in "$OPTICAL_ROOT" "$MODERN_ROOT"; do
    for sys_dir in "$bucket_root"/*/; do
        find "$sys_dir" -type f -delete 2>/dev/null
        find "$sys_dir" -depth -type d -empty -delete 2>/dev/null || true
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
    mkdir -p "$cartridge" "$quarantine"
    
    "$IGIR" move test report \
        --dat "$dat" \
        --input "$incoming" \
        --output "$cartridge" \
        --report-output "$report" \
        --dir-game-subdir never 2>&1 | tail -5
    
    # Quarantine leftovers
    local qcount=0
    while IFS= read -r -d '' f; do
        [[ "$f" == *.aria2 ]] && continue
        rel="${f#"$incoming"/}"
        base=$(basename -- "$f")
        if [[ -e "$cartridge/$rel" ]] || [[ -e "$cartridge/$base" ]] || [[ -n "$(find "$cartridge" -type f -name "$base" -print -quit 2>/dev/null)" ]]; then
            rm -f -- "$f"
        else
            mkdir -p "$quarantine/$(dirname "$rel")"
            mv -f -- "$f" "$quarantine/$rel"
            qcount=$((qcount + 1))
        fi
    done < <(find "$incoming" -type f -print0)
    
    find "$incoming" -depth -type d -empty -delete 2>/dev/null || true
    echo "    Done: $(find "$cartridge" -type f | wc -l) files promoted, $qcount quarantined"
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
    mkdir -p "$cartridge" "$quarantine"
    "$IGIR" move test report \
        --dat "$dat" \
        --input "$incoming" \
        --output "$cartridge" \
        --report-output "$report" \
        --dir-game-subdir never 2>&1 | tail -5
    
    qcount=0
    while IFS= read -r -d '' f; do
        [[ "$f" == *.aria2 ]] && continue
        rel="${f#"$incoming"/}"
        base=$(basename -- "$f")
        if [[ -e "$cartridge/$rel" ]] || [[ -e "$cartridge/$base" ]] || [[ -n "$(find "$cartridge" -type f -name "$base" -print -quit 2>/dev/null)" ]]; then
            rm -f -- "$f"
        else
            mkdir -p "$quarantine/$(dirname "$rel")"
            mv -f -- "$f" "$quarantine/$rel"
            qcount=$((qcount + 1))
        fi
    done < <(find "$incoming" -type f -print0)
    find "$incoming" -depth -type d -empty -delete 2>/dev/null || true
    echo "    Done: $(find "$cartridge" -type f | wc -l) files promoted, $qcount quarantined"
fi

echo ""
echo "=== Complete ==="
echo "Cartridge bucket:"
for d in "$CART_ROOT"/*/; do
    count=$(find "$d" -type f -name "*.zip" 2>/dev/null | wc -l)
    echo "  $(basename "$d"): $count"
done
echo "Optical bucket:"
for d in "$OPTICAL_ROOT"/*/; do
    count=$(find "$d" -type f 2>/dev/null | wc -l)
    echo "  $(basename "$d"): $count"
done