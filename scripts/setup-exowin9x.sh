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

SOURCE_ARCHIVE="${1:-}"
if [[ -z "${SOURCE_ARCHIVE}" ]]; then
    echo "Usage: $0 <path-to-exowin9x-archive.7z>"
    echo ""
    echo "Example:"
    echo "  $0 /tank/archive/retro/downloads/eXoWin9x_Vol1_v1.0.7z"
    exit 1
fi

if [[ ! -f "${SOURCE_ARCHIVE}" ]]; then
    echo "ERROR: Archive not found: ${SOURCE_ARCHIVE}"
    exit 1
fi

# Configuration
ARCHIVE_DIR="/tank/archive/retro/games/curated"
TARGET_DIR="${ARCHIVE_DIR}/exo-win9x"
TARGET_DATASET="tank/archive/retro/games/curated/exo-win9x"
WORK_DIR="/tmp/exowin9x-extract"
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
log "Source archive: ${SOURCE_ARCHIVE}"
log "Target location: ${TARGET_DIR}"
log "Log: ${LOG_FILE}"
log ""

# Extract archive to temporary location
log "Extracting 7z archive (may take 10-30 minutes)..."
mkdir -p "${WORK_DIR}"
7z x -o"${WORK_DIR}" "${SOURCE_ARCHIVE}" || error "Failed to extract archive"
success "Extraction complete"

# Move extracted collection to target via ZFS send/recv
log "Consolidating to ZFS dataset ${TARGET_DATASET}..."

# Check if dataset exists
if zfs list -H "${TARGET_DATASET}" &>/dev/null; then
    log "Dataset already exists, destroying..."
    zfs destroy -r "${TARGET_DATASET}" || error "Failed to destroy existing dataset"
fi

# Create dataset from extracted archive
log "Creating ZFS dataset from extracted content..."
tar -C "${WORK_DIR}" -cf - . | zfs recv -F "${TARGET_DATASET}" || error "Failed to send/recv dataset"
success "ZFS dataset created"

# Verify structure
log ""
log "Verifying collection structure..."
zfs list -H "${TARGET_DATASET}" && success "Dataset is mounted and accessible"

# Count games
game_count=$(find "${TARGET_DIR}/Games" -maxdepth 1 -type d 2>/dev/null | wc -l)
if [[ $game_count -gt 0 ]]; then
    success "Found ~${game_count} game directories"
fi

# Clean up temporary extraction
log "Cleaning up temporary files..."
rm -rf "${WORK_DIR}"
success "Temporary files removed"

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
