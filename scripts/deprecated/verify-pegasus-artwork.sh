#!/bin/bash
# verify-pegasus-artwork.sh — Verify Pegasus artwork displays correctly (trap fixture)
#
# This is the CRITICAL verification per GROUND-TRUTH-pegasus-assets.md:
# - Metadata files exist and parse
# - Games appear in Pegasus UI
# - Asset paths resolve correctly
# - **Artwork actually displays** (not black, not missing)
#
# This script automates the diagnostics from the trap fixture.
# Manual Pegasus UI test still required to verify artwork visually.
#
# Usage: ./verify-pegasus-artwork.sh [--pegasus-config /home/gamer/.config/pegasus-frontend]

set -eu

PEGASUS_CONFIG="${1:---pegasus-config}"
if [ "$PEGASUS_CONFIG" = "--pegasus-config" ]; then
  PEGASUS_CONFIG="${2:-$HOME/.config/pegasus-frontend}"
fi

if [ ! -d "$PEGASUS_CONFIG" ]; then
  echo "ERROR: Pegasus config directory not found: $PEGASUS_CONFIG"
  exit 1
fi

PASS=0
FAIL=0
WARN=0

log_pass() { echo "  ✓ $1"; ((PASS++)); }
log_fail() { echo "  ✗ $1"; ((FAIL++)); }
log_warn() { echo "  ⚠ $1"; ((WARN++)); }

echo "[$(date)] Verifying Pegasus artwork display (trap fixture)"
echo ""

# --- Check 1: game_dirs.txt -------------------------------------------------------

echo "1. Check game_dirs.txt configuration:"

GAME_DIRS="$PEGASUS_CONFIG/game_dirs.txt"
if [ ! -f "$GAME_DIRS" ]; then
  log_fail "game_dirs.txt not found"
  exit 1
fi

COLL_COUNT=$(grep -c "^/" "$GAME_DIRS" || echo 0)
if [ "$COLL_COUNT" -lt 5 ]; then
  log_fail "game_dirs.txt has only $COLL_COUNT directories (expected 20+)"
else
  log_pass "game_dirs.txt lists $COLL_COUNT directories"
fi

# Check for specific collections
if grep -q "curated-exo-dos" "$GAME_DIRS"; then
  log_pass "game_dirs.txt includes curated-exo-dos"
else
  log_fail "game_dirs.txt missing curated-exo-dos"
fi

if grep -q "curated-exo-win3x" "$GAME_DIRS"; then
  log_pass "game_dirs.txt includes curated-exo-win3x"
else
  log_fail "game_dirs.txt missing curated-exo-win3x"
fi

echo ""

# --- Check 2: Metadata files exist -----------------------------------------------

echo "2. Check metadata files exist:"

COLLECTIONS_DIR=$(head -1 "$GAME_DIRS" | xargs dirname | xargs dirname)
if [ ! -d "$COLLECTIONS_DIR" ]; then
  log_fail "Collections directory not found: $COLLECTIONS_DIR"
  exit 1
fi

FILE_COUNT=$(find "$COLLECTIONS_DIR" -name "metadata.pegasus.txt" 2>/dev/null | wc -l || echo 0)
if [ "$FILE_COUNT" -lt 5 ]; then
  log_fail "Found only $FILE_COUNT metadata files (expected 20+)"
else
  log_pass "Found $FILE_COUNT metadata.pegasus.txt files"
fi

echo ""

# --- Check 3: Pegasus logs for parse errors -----------------------------------------------

echo "3. Check Pegasus logs for errors:"

LOG_FILE="$PEGASUS_CONFIG/lastrun.log"
if [ ! -f "$LOG_FILE" ]; then
  log_warn "Pegasus log not found: $LOG_FILE (needs Pegasus to have run)"
else
  ERROR_COUNT=$(grep -i "error" "$LOG_FILE" | wc -l || echo 0)
  PARSE_ERROR_COUNT=$(grep -i "parse" "$LOG_FILE" | wc -l || echo 0)

  if [ "$ERROR_COUNT" -gt 0 ]; then
    log_fail "Found $ERROR_COUNT ERROR lines in Pegasus log"
    grep -i "error" "$LOG_FILE" | head -3 | sed 's/^/    /'
  else
    log_pass "No ERROR lines in Pegasus log"
  fi

  if [ "$PARSE_ERROR_COUNT" -gt 0 ]; then
    log_fail "Found $PARSE_ERROR_COUNT parse errors in Pegasus log"
  else
    log_pass "No parse errors in Pegasus log"
  fi
fi

echo ""

# --- Check 4: NFS mount is readable -----------------------------------------------

echo "4. Check NFS mount (must be readable from kiosk):"

NFS_MOUNT="/tank/archive/retro"
if mount | grep -q "$NFS_MOUNT"; then
  MNT_MODE=$(mount | grep "$NFS_MOUNT" | grep -o "ro\|rw" | head -1)
  log_pass "NFS mount exists at $NFS_MOUNT (mode: $MNT_MODE)"
else
  log_fail "NFS mount $NFS_MOUNT not mounted"
  exit 1
fi

# Check readability
if [ ! -r "$NFS_MOUNT/metadata/pegasus" ]; then
  log_fail "Metadata directory not readable: $NFS_MOUNT/metadata/pegasus"
else
  log_pass "Metadata directory readable from kiosk"
fi

echo ""

# --- Check 5: Asset paths resolve -----------------------------------------------

echo "5. Check asset paths resolve (critical trap fixture test):"

# Sample eXoDOS metadata
SAMPLE_METADATA="$COLLECTIONS_DIR/curated-exo-dos/metadata.pegasus.txt"
if [ ! -f "$SAMPLE_METADATA" ]; then
  log_warn "eXoDOS metadata not found (collection may not be installed)"
else
  # Extract first game with assets.box_front
  ASSET_LINE=$(grep "^assets.box_front:" "$SAMPLE_METADATA" | head -1)

  if [ -z "$ASSET_LINE" ]; then
    log_warn "No assets.box_front entries in eXoDOS metadata"
  else
    # Get the directory and asset path
    DIRECTORY=$(grep "^directory:" "$SAMPLE_METADATA" | head -1 | cut -d: -f2- | xargs)
    ASSET_PATH=$(echo "$ASSET_LINE" | cut -d: -f2- | xargs)

    # Reconstruct full path
    FULL_PATH="$DIRECTORY/$ASSET_PATH"

    if [ -e "$FULL_PATH" ]; then
      log_pass "Sample asset path resolves: $ASSET_PATH"

      # Check file is readable and non-zero
      if [ -r "$FULL_PATH" ] && [ -s "$FULL_PATH" ]; then
        SIZE=$(stat -c%s "$FULL_PATH" 2>/dev/null || echo "?")
        log_pass "Asset file readable and non-empty ($SIZE bytes)"
      else
        log_fail "Asset file not readable or empty"
      fi
    else
      log_fail "Asset path doesn't resolve: $FULL_PATH"
      log_fail "  Directory: $DIRECTORY"
      log_fail "  Asset: $ASSET_PATH"
    fi
  fi
fi

echo ""

# --- Check 6: Asset symlinks (on europa perspective, informational) -----------------------------------------------

echo "6. Check asset symlinks (on europa):"

ASSETS_DIR="$NFS_MOUNT/metadata/pegasus/assets"
if [ ! -d "$ASSETS_DIR" ]; then
  log_warn "Assets directory not found on NFS: $ASSETS_DIR"
  log_warn "  (This is normal if assets haven't been generated yet)"
else
  SYMLINK_COUNT=$(find "$ASSETS_DIR" -type l 2>/dev/null | wc -l || echo 0)
  if [ "$SYMLINK_COUNT" -gt 0 ]; then
    log_pass "Found $SYMLINK_COUNT asset symlinks"

    # Check a sample symlink
    SAMPLE_LINK=$(find "$ASSETS_DIR" -type l 2>/dev/null | head -1)
    if [ -n "$SAMPLE_LINK" ]; then
      TARGET=$(readlink -f "$SAMPLE_LINK" 2>/dev/null || echo "?")
      if [ -e "$TARGET" ]; then
        log_pass "Sample symlink resolves: $SAMPLE_LINK"
      else
        log_fail "Sample symlink target doesn't exist: $TARGET"
      fi
    fi
  else
    log_warn "No asset symlinks found (may need to regenerate metadata)"
  fi
fi

echo ""

# --- Check 7: Game counts -------------------------------------------------------

echo "7. Check game counts:"

if [ -f "$SAMPLE_METADATA" ]; then
  GAME_COUNT=$(grep -c "^game:" "$SAMPLE_METADATA" || echo 0)
  if [ "$GAME_COUNT" -gt 100 ]; then
    log_pass "eXoDOS has $GAME_COUNT games"
  else
    log_warn "eXoDOS has only $GAME_COUNT games (expected 500+)"
  fi
fi

# Check 1G1R collections
NES_METADATA="$COLLECTIONS_DIR/1g1r-nointro-nes/metadata.pegasus.txt"
if [ -f "$NES_METADATA" ]; then
  NES_COUNT=$(grep -c "^game:" "$NES_METADATA" || echo 0)
  if [ "$NES_COUNT" -gt 500 ]; then
    log_pass "1G1R NES has $NES_COUNT games"
  else
    log_warn "1G1R NES has only $NES_COUNT games"
  fi
fi

echo ""

# --- Summary -------------------------------------------------------

echo "Verification Summary:"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "  WARN: $WARN"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "❌ VERIFICATION FAILED"
  echo ""
  echo "Troubleshooting steps:"
  echo "1. Check game_dirs.txt lists all 25 collection directories"
  echo "2. Regenerate metadata on europa: generate-arcade-metadata.py --collections all"
  echo "3. Verify asset symlinks: find /tank/archive/retro/metadata/pegasus/assets -type l | head"
  echo "4. Check Pegasus logs for parse errors"
  echo ""
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo "⚠️  VERIFICATION PASSED WITH WARNINGS"
  echo ""
  echo "Some collections may not be fully installed:"
  echo "- Check if LaunchBox archives were extracted on europa"
  echo "- Verify metadata was regenerated for all collections"
  echo "- If assets are missing, re-run extract-launchbox-metadata.sh"
  echo ""
  exit 0
else
  echo "✅ VERIFICATION PASSED"
  echo ""
  echo "Next: Open Pegasus UI and test manual verification:"
  echo "1. Select eXoDOS or eXoWin3x collection"
  echo "2. Select a game (e.g., 'Commander Keen' or 'Magic Carpet')"
  echo "3. Verify BOXART IMAGE DISPLAYS (critical trap fixture test)"
  echo "   - Should show game artwork, not black/missing"
  echo "   - Should show developer, publisher, genre, etc."
  echo ""
  echo "If artwork is BLACK or MISSING:"
  echo "- Check asset paths in metadata file"
  echo "- Verify symlinks resolve: readlink -f /tank/archive/retro/metadata/pegasus/assets/.../boxart/*"
  echo "- Check NFS mount permissions: mount | grep /tank/archive"
  echo ""
  exit 0
fi
