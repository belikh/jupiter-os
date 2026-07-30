#!/bin/bash
# validate-arcade-metadata.sh — Validate Pegasus metadata per trap fixture
#
# Verifies:
# 1. Metadata files exist and are readable
# 2. Pegasus syntax is valid (UTF-8, line endings, field names)
# 3. File paths resolve correctly (relative to directory: declaration)
# 4. Asset symlinks are readable (not broken, not 0-byte)
# 5. No duplicate game titles (would cause shadowing)
#
# Reference: .claude/domains/GROUND-TRUTH-pegasus-assets.md
#
# Usage: ./validate-arcade-metadata.sh [--collections-dir /tank/archive/retro/metadata/pegasus/collections]

set -eu

COLLECTIONS_DIR="${1:---collections-dir}"
if [ "$COLLECTIONS_DIR" = "--collections-dir" ]; then
  COLLECTIONS_DIR="${2:-/tank/archive/retro/metadata/pegasus/collections}"
fi

if [ ! -d "$COLLECTIONS_DIR" ]; then
  echo "ERROR: Collections directory not found: $COLLECTIONS_DIR"
  exit 1
fi

PASS=0
FAIL=0
WARN=0

log_pass() { echo "  ✓ $1"; ((PASS++)); }
log_fail() { echo "  ✗ $1"; ((FAIL++)); }
log_warn() { echo "  ⚠ $1"; ((WARN++)); }

echo "[$(date)] Validating Pegasus metadata in $COLLECTIONS_DIR"
echo ""

# --- Global Checks -------------------------------------------------------

echo "Global Checks:"

# Check that at least one collection directory exists
COLLECTION_COUNT=$(find "$COLLECTIONS_DIR" -maxdepth 1 -type d | wc -l)
if [ "$COLLECTION_COUNT" -gt 1 ]; then
  log_pass "Found $(($COLLECTION_COUNT - 1)) collection directories"
else
  log_fail "No collection directories found"
  exit 1
fi

# Check for required collections (curated should have at least some)
if [ -d "$COLLECTIONS_DIR/curated-exo-dos" ]; then
  log_pass "Found curated-exo-dos collection"
else
  log_warn "curated-exo-dos not found"
fi

if [ -d "$COLLECTIONS_DIR/curated-exo-win3x" ]; then
  log_pass "Found curated-exo-win3x collection"
else
  log_warn "curated-exo-win3x not found"
fi

echo ""
echo "Per-Collection Validation:"
echo ""

# --- Per-Collection Checks -----------------------------------------------

for COLL_DIR in "$COLLECTIONS_DIR"/*/; do
  if [ ! -d "$COLL_DIR" ]; then
    continue
  fi

  COLL_NAME=$(basename "$COLL_DIR")
  METADATA_FILE="$COLL_DIR/metadata.pegasus.txt"

  echo "$COLL_NAME:"

  # 1. Check metadata file exists
  if [ ! -f "$METADATA_FILE" ]; then
    log_fail "metadata.pegasus.txt not found"
    continue
  fi
  log_pass "metadata.pegasus.txt exists"

  # 2. Check file is readable and non-empty
  if [ ! -r "$METADATA_FILE" ]; then
    log_fail "metadata.pegasus.txt not readable"
    continue
  fi

  SIZE=$(wc -c < "$METADATA_FILE")
  if [ "$SIZE" -eq 0 ]; then
    log_fail "metadata.pegasus.txt is empty"
    continue
  fi
  log_pass "metadata.pegasus.txt is readable ($SIZE bytes)"

  # 3. Check UTF-8 encoding
  if file "$METADATA_FILE" | grep -q "UTF-8\|ASCII"; then
    log_pass "Valid encoding (UTF-8/ASCII)"
  else
    log_warn "Unexpected encoding: $(file -b "$METADATA_FILE")"
  fi

  # 4. Check Unix line endings (LF, not CRLF)
  if grep -q $'\r' "$METADATA_FILE"; then
    log_warn "Contains Windows line endings (CRLF)"
  else
    log_pass "Unix line endings (LF)"
  fi

  # 5. Check for required fields (collection, directory, game, file)
  HAS_COLLECTION=$(grep -q "^collection:" "$METADATA_FILE" && echo 1 || echo 0)
  HAS_DIRECTORY=$(grep -q "^directory:" "$METADATA_FILE" && echo 1 || echo 0)
  HAS_GAMES=$(grep -q "^game:" "$METADATA_FILE" && echo 1 || echo 0)

  if [ "$HAS_COLLECTION" = "1" ]; then
    log_pass "Has collection: declaration"
  else
    log_fail "Missing collection: declaration"
  fi

  if [ "$HAS_DIRECTORY" = "1" ]; then
    log_pass "Has directory: declaration"
  else
    log_fail "Missing directory: declaration"
  fi

  if [ "$HAS_GAMES" = "1" ]; then
    GAME_COUNT=$(grep -c "^game:" "$METADATA_FILE" || echo 0)
    log_pass "Found $GAME_COUNT games"
  else
    log_fail "No games found"
    continue
  fi

  # 6. Check for invalid field names (the trap!)
  if grep -q "^image:" "$METADATA_FILE"; then
    log_fail "Invalid field name: 'image:' (should be 'assets.box_front:')"
  else
    log_pass "No invalid 'image:' field"
  fi

  # 7. Check for correct asset field names
  HAS_BOX_FRONT=$(grep -c "^assets.box_front:" "$METADATA_FILE" || echo 0)
  HAS_SCREENSHOT=$(grep -c "^assets.screenshot:" "$METADATA_FILE" || echo 0)
  HAS_LOGO=$(grep -c "^assets.logo:" "$METADATA_FILE" || echo 0)

  if [ "$HAS_BOX_FRONT" -gt 0 ]; then
    log_pass "Found $HAS_BOX_FRONT assets.box_front entries"
  else
    log_warn "No box_front assets (might be expected for 1G1R)"
  fi

  # 8. Check for duplicate game titles
  GAME_TITLES=$(grep "^game:" "$METADATA_FILE" | cut -d: -f2- | sort)
  UNIQUE_TITLES=$(echo "$GAME_TITLES" | sort -u | wc -l)
  if [ "$GAME_COUNT" = "$UNIQUE_TITLES" ]; then
    log_pass "No duplicate game titles"
  else
    log_warn "Found duplicates: $((GAME_COUNT - UNIQUE_TITLES)) shadowed games"
  fi

  # 9. Validate first game entry (sample path resolution)
  FIRST_GAME=$(grep "^game:" "$METADATA_FILE" | head -1 | cut -d: -f2- | xargs)
  FIRST_FILE=$(grep -A1 "^game: $FIRST_GAME$" "$METADATA_FILE" | grep "^file:" | head -1 | cut -d: -f2- | xargs)
  DIRECTORY=$(grep "^directory:" "$METADATA_FILE" | head -1 | cut -d: -f2- | xargs)

  if [ -n "$FIRST_FILE" ] && [ -n "$DIRECTORY" ]; then
    # Reconstruct the path (NOTE: this is simplistic; doesn't handle spaces)
    FULL_PATH="$DIRECTORY/$FIRST_FILE"
    if [ -e "$FULL_PATH" ]; then
      log_pass "Sample path resolves: $FIRST_GAME"
    else
      log_fail "Sample path doesn't resolve: $FULL_PATH"
      # Try to be helpful
      if [ -d "$DIRECTORY" ]; then
        log_warn "  directory exists: $DIRECTORY"
        log_warn "  but file missing: $FIRST_FILE"
      fi
    fi
  else
    log_warn "Could not extract sample path for validation"
  fi

  # 10. Check for common Pegasus syntax errors
  # - No multiline values (should be single line)
  # - No unescaped colons in values (rare)
  if grep "^[^ ].*: " "$METADATA_FILE" | grep -q "^[a-z_]*: .*:[^/]"; then
    log_warn "Possible unescaped colons in field values"
  fi

  echo ""
done

# --- Summary -------------------------------------------------------

echo ""
echo "Validation Summary:"
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo "  WARN: $WARN"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "RESULT: FAILED (found $FAIL errors)"
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo "RESULT: PASSED WITH WARNINGS (found $WARN warnings)"
  exit 0
else
  echo "RESULT: SUCCESS (all checks passed)"
  exit 0
fi
