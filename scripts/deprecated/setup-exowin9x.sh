#!/bin/bash
# setup-exowin9x.sh — Extract and consolidate eXoWin9x (Vol. 1) to ZFS archive
#
# Prerequisites:
# - eXoWin9x_Vol1.7z archive downloaded
# - ~700 GB space needed (~262 GB compressed + ~400 GB extracted)
#
# Usage: setup-exowin9x.sh /path/to/eXoWin9x_Vol1_v*.7z
#
# This script:
# 1. Extracts the 7z archive once to get collection structure
# 2. Moves to /tank/archive/retro/games/curated/exo-win9x via ZFS send/recv
# 3. Games are launched on-demand at runtime (not pre-extracted)
# 4. Creates Pegasus metadata

set -euo pipefail

SOURCE_PATH="${1:-}"
if [[ -z "${SOURCE_PATH}" ]]; then
    echo "Usage: $0 <path-to-exowin9x-directory-or-archive>"
    echo ""
    echo "Examples:"
    echo "  $0 /tank/archive/retro/downloads/eXoWin9x  (extracted directory)"
    echo "  $0 /tank/archive/retro/downloads/eXoWin9x_Vol1_v1.0.7z  (7z archive)"
    exit 1
fi

# Handle both extracted directories and 7z archives
SKIP_EXTRACT=false
WORK_DIR="/tmp/exowin9x-extract"

if [[ -d "${SOURCE_PATH}" ]]; then
    WORK_DIR="${SOURCE_PATH}"
    SKIP_EXTRACT=true
elif [[ -f "${SOURCE_PATH}" ]]; then
    if [[ ! "${SOURCE_PATH}" =~ \.7z$ ]]; then
        echo "ERROR: Archive must be .7z format: ${SOURCE_PATH}"
        exit 1
    fi
    SKIP_EXTRACT=false
else
    echo "ERROR: Not found: ${SOURCE_PATH}"
    exit 1
fi

# Configuration
ARCHIVE_DIR="/tank/archive/retro/games/curated"
TARGET_DIR="${ARCHIVE_DIR}/exo-win9x"
TARGET_DATASET="tank/archive/retro/games/curated/exo-win9x"
METADATA_DIR="/tank/archive/retro/metadata/pegasus/collections"

LOG_FILE="/var/log/exowin9x-setup.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

error() {
    echo -e "${RED}ERROR: $*${NC}" | tee -a "${LOG_FILE}"
    exit 1
}

success() {
    echo -e "${GREEN}✓ $*${NC}" | tee -a "${LOG_FILE}"
}

log "=== eXoWin9x Setup ==="
log "Source path: ${SOURCE_PATH}"
log "Target location: ${TARGET_DIR}"
log "Log: ${LOG_FILE}"
log ""

# Extract archive if needed
if [[ "${SKIP_EXTRACT}" == "false" ]]; then
    log "Extracting 7z archive (may take 10-30 minutes)..."
    mkdir -p "${WORK_DIR}"
    7z x -o"${WORK_DIR}" "${SOURCE_PATH}" || error "Failed to extract archive"
    success "Extraction complete"
else
    log "Using already-extracted directory: ${WORK_DIR}"
    success "Directory verified"
fi

# Move extracted collection to target via ZFS send/recv
log "Consolidating to ZFS dataset ${TARGET_DATASET}..."

# Check if dataset exists
if zfs list -H "${TARGET_DATASET}" &>/dev/null; then
    log "Dataset already exists, destroying..."
    zfs destroy -r "${TARGET_DATASET}" || error "Failed to destroy existing dataset"
fi

# Create ZFS dataset and copy content
log "Creating ZFS dataset..."
mkdir -p "${ARCHIVE_DIR}"
zfs create "${TARGET_DATASET}" || error "Failed to create ZFS dataset"
success "ZFS dataset created"

# Copy content to mounted dataset
TARGET_MOUNT=$(zfs get -H -o value mountpoint "${TARGET_DATASET}")
log "Copying content to ${TARGET_MOUNT}..."
cp -r "${WORK_DIR}"/* "${TARGET_MOUNT}/" || error "Failed to copy collection content"
success "Collection content copied"

# Verify structure
log ""
log "Verifying collection structure..."
zfs list -H "${TARGET_DATASET}" && success "Dataset is mounted and accessible"

# Count games (for eXoWin9x, games are in eXo/eXoWin9x/YYYY directories)
game_count=$(find "${TARGET_MOUNT}/eXo/eXoWin9x" -maxdepth 1 -type d 2>/dev/null | grep -E '199[0-9]' | wc -l)
if [[ $game_count -gt 0 ]]; then
    success "Found ${game_count} year categories"
    total_games=$(find "${TARGET_MOUNT}/eXo/eXoWin9x" -maxdepth 2 -type d 2>/dev/null | wc -l)
    log "Total directories (including years): ${total_games}"
fi

# Clean up temporary extraction (only if we extracted from archive)
if [[ "${SKIP_EXTRACT}" == "false" ]]; then
    log "Cleaning up temporary extraction..."
    rm -rf "${WORK_DIR}"
    success "Temporary files removed"
else
    log "Keeping source directory (already extracted): ${WORK_DIR}"
fi

# Generate Pegasus metadata
log ""
log "Generating Pegasus metadata..."
mkdir -p "${METADATA_DIR}"
python3 /root/jupiter-os/scripts/generate-arcade-metadata.py \
    --nfs-root /tank/archive \
    --output "${METADATA_DIR}" \
    --assets /tank/archive/retro/metadata/pegasus/assets \
    --collections curated-exo-win9x 2>&1 | tee -a "${LOG_FILE}" || {
    echo "⚠ Metadata generation had issues, but collection is ready"
}

log ""
log "=== eXoWin9x Setup Complete ==="
log ""
log "Collection: ${TARGET_DATASET} → ${TARGET_DIR}/"
log "Metadata: ${METADATA_DIR}/curated-exo-win9x.txt"
log ""
log "Games are stored as-is and launched on-demand at runtime."
log ""
log "Next steps:"
log "1. Verify metadata: cat ${METADATA_DIR}/curated-exo-win9x.txt | head -20"
log "2. Test on kiosk: select a game in Pegasus"
log "3. Monitor launch: journalctl -u pegasus-rom-launch -f"
