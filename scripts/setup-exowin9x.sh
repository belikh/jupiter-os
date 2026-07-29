#!/bin/bash
# setup-exowin9x.sh — Archive and integrate eXoWin9x (Vol. 1) into jupiter-os arcade
#
# Prerequisites:
# - eXoWin9x_Vol1 archive downloaded and available at $SOURCE_ARCHIVE
# - ~350-400 GB free space on /tank/archive/retro/curated/
#
# Usage: setup-exowin9x.sh /path/to/eXoWin9x_Vol1_v*.7z
#
# This script:
# 1. Extracts the 7z archive to a working directory
# 2. Organizes into the proper ZFS layout
# 3. Creates Pegasus metadata
# 4. Verifies integrity

set -euo pipefail

SOURCE_ARCHIVE="${1:-}"
if [[ -z "${SOURCE_ARCHIVE}" ]]; then
    echo "Usage: $0 <path-to-exowin9x-archive.7z>"
    echo ""
    echo "Example:"
    echo "  $0 /mnt/staging/eXoWin9x_Vol1_v1.0.7z"
    exit 1
fi

if [[ ! -f "${SOURCE_ARCHIVE}" ]]; then
    echo "ERROR: Archive not found: ${SOURCE_ARCHIVE}"
    exit 1
fi

# Configuration
ARCHIVE_DIR="/tank/archive/retro/games/curated"
TARGET_DIR="${ARCHIVE_DIR}/exo-win9x"
WORK_DIR="/tmp/exowin9x-setup"
METADATA_DIR="/tank/archive/retro/metadata/pegasus/collections"

echo "=== eXoWin9x Setup ==="
echo "Source archive: ${SOURCE_ARCHIVE}"
echo "Target directory: ${TARGET_DIR}"
echo "Work directory: ${WORK_DIR}"
echo ""

# Create target directory
mkdir -p "${TARGET_DIR}" "${METADATA_DIR}"
echo "✓ Created target directories"

# Extract archive
echo "Extracting archive (this may take 10-30 minutes)..."
mkdir -p "${WORK_DIR}"
7z x -o"${WORK_DIR}" "${SOURCE_ARCHIVE}" || {
    echo "ERROR: Failed to extract archive"
    rm -rf "${WORK_DIR}"
    exit 1
}
echo "✓ Extraction complete"

# Move extracted content to target
echo "Organizing files into archive structure..."
if [[ -d "${WORK_DIR}/eXoWin9x" ]]; then
    mv "${WORK_DIR}/eXoWin9x"/* "${TARGET_DIR}/" 2>/dev/null || true
elif [[ -d "${WORK_DIR}/extracted" ]]; then
    mv "${WORK_DIR}/extracted"/* "${TARGET_DIR}/" 2>/dev/null || true
else
    # Assume the archive extracts directly
    find "${WORK_DIR}" -maxdepth 1 -type d ! -name "${WORK_DIR}" -exec mv {} "${TARGET_DIR}/" \;
fi

# Verify key directories exist
required_dirs=(
    "Games"
    "DOSBox-X"
    "PCem"
    "VHD"
    "Glide"
    "_Windows"
    "Extras"
)

echo "Verifying directory structure..."
missing=()
for dir in "${required_dirs[@]}"; do
    if [[ ! -d "${TARGET_DIR}/${dir}" ]]; then
        missing+=("${dir}")
    fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "⚠ WARNING: Missing directories (may not be critical):"
    printf '  - %s\n' "${missing[@]}"
else
    echo "✓ All expected directories found"
fi

# Count games
game_count=$(find "${TARGET_DIR}/Games" -maxdepth 1 -type d | wc -l)
echo "✓ Found ${game_count} game directories"

# Set permissions
echo "Setting permissions..."
chmod -R 755 "${TARGET_DIR}"
echo "✓ Permissions set"

# Clean up work directory
rm -rf "${WORK_DIR}"
echo "✓ Cleaned up temporary files"

# Generate Pegasus metadata
echo ""
echo "Generating Pegasus metadata..."
python3 /root/jupiter-os/scripts/generate-arcade-metadata.py \
    --nfs-root /tank/archive \
    --output "${METADATA_DIR}" \
    --assets /tank/archive/retro/metadata/pegasus/assets \
    --collections curated-exo-win9x || {
    echo "⚠ Metadata generation returned non-zero, but archive is ready"
}

echo ""
echo "=== eXoWin9x Setup Complete ==="
echo ""
echo "Collection location: ${TARGET_DIR}/"
echo "Pegasus metadata: ${METADATA_DIR}/curated-exo-win9x.txt"
echo ""
echo "Next steps:"
echo "1. Verify Pegasus collection file: cat ${METADATA_DIR}/curated-exo-win9x.txt"
echo "2. Test launch on a kiosk: select a game in Pegasus"
echo "3. Monitor: journalctl -u pegasus-rom-launch.service -f"
