#!/bin/bash
# extract-launchbox-metadata.sh — Extract LaunchBox metadata zips for arcade collections
#
# Extracts XML + image archives from eXoDOS and eXoWin3x LaunchBox archives
# to the expected structure for generate-arcade-metadata.py:
#   /tank/archive/retro/games/curated/{exo-dos,exo-win3x}/xml/
#   /tank/archive/retro/games/curated/{exo-dos,exo-win3x}/Images-extract/
#
# Usage: ./extract-launchbox-metadata.sh [--base-path /tank/archive/retro/games]

set -eu

BASE_PATH="${1:---base-path}"
if [ "$BASE_PATH" = "--base-path" ]; then
  BASE_PATH="${2:-/tank/archive/retro/games}"
fi

COLLECTIONS=(
  "curated/exo-dos"
  "curated/exo-win3x"
  "curated/c64-dreams"
  "curated/exo-scummvm"
)

echo "[$(date)] Starting LaunchBox metadata extraction..."

for COLL in "${COLLECTIONS[@]}"; do
  COLL_PATH="$BASE_PATH/$COLL"

  if [ ! -d "$COLL_PATH" ]; then
    echo "  SKIP: $COLL (directory not found)"
    continue
  fi

  echo "  Processing: $COLL"

  # Look for LaunchBox archive files
  # LaunchBox collections are typically delivered as:
  # - Single .7z or .zip (entire collection)
  # - Multiple .zip files (e.g., part1.zip, part2.zip)
  # - Metadata zip separate from game zips (e.g., eXoDOS-LaunchBox.zip)

  ARCHIVES=()
  for archive in "$COLL_PATH"/*.{7z,zip} "$COLL_PATH"/LaunchBox*.{7z,zip} 2>/dev/null || true; do
    if [ -f "$archive" ]; then
      ARCHIVES+=("$archive")
    fi
  done

  if [ ${#ARCHIVES[@]} -eq 0 ]; then
    echo "    No archives found in $COLL_PATH"
    continue
  fi

  # Extract metadata (XML) and images from each archive
  for archive in "${ARCHIVES[@]}"; do
    echo "    Extracting: $(basename "$archive")"

    # Create temporary extraction directory
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT

    # Determine archive type and extract
    case "$archive" in
      *.7z)
        7z x "$archive" -o"$TEMP_DIR" > /dev/null 2>&1 || true
        ;;
      *.zip)
        unzip -q "$archive" -d "$TEMP_DIR" || true
        ;;
    esac

    # Move XML metadata if found
    # LaunchBox XML is typically in Data/Platforms/ or root LaunchBox/ directory
    if [ -d "$TEMP_DIR/Data/Platforms" ]; then
      mkdir -p "$COLL_PATH/xml"
      cp "$TEMP_DIR"/Data/Platforms/*.xml "$COLL_PATH/xml/" 2>/dev/null || true
      echo "      → Extracted XML metadata to xml/"
    fi

    # Move image archives if found
    # Images are typically in Images/ or LaunchBox/Images/
    if [ -d "$TEMP_DIR/Images" ]; then
      mkdir -p "$COLL_PATH/Images-extract"
      cp -r "$TEMP_DIR"/Images/* "$COLL_PATH/Images-extract/" 2>/dev/null || true
      echo "      → Extracted images to Images-extract/"
    elif [ -d "$TEMP_DIR/LaunchBox/Images" ]; then
      mkdir -p "$COLL_PATH/Images-extract"
      cp -r "$TEMP_DIR"/LaunchBox/Images/* "$COLL_PATH/Images-extract/" 2>/dev/null || true
      echo "      → Extracted images to Images-extract/"
    fi

    rm -rf "$TEMP_DIR"
  done
done

echo "[$(date)] LaunchBox metadata extraction complete."
echo ""
echo "Next step: Run generate-arcade-metadata.py to create Pegasus collection files"
echo "  python3 /home/io/Projects/jupiter-os/scripts/generate-arcade-metadata.py \\"
echo "    --nfs-root /tank/archive \\"
echo "    --output /tank/archive/retro/metadata/pegasus/collections \\"
echo "    --assets /tank/archive/retro/metadata/pegasus/assets \\"
echo "    --collections all"
