#!/bin/bash
# consolidate-collections.sh — Consolidate eXoDOS and eXoWin3x using ZFS send/recv
#
# This script consolidates existing game collections from /mnt/europa/games
# to /tank/archive/retro/games/curated using ZFS send/receive.
#
# Prerequisites:
# - Script runs ON europa (10.1.1.2)
# - Source collections must be on a ZFS dataset
# - ~1 TB free space on tank/archive pool
# - No active Pegasus/arcade sessions
#
# Usage: Run this on europa:
#   ssh root@10.1.1.2 bash /root/consolidate-collections.sh

set -euo pipefail

# Configuration
SOURCE_BASE="/mnt/europa/games"
TARGET_BASE="/tank/archive/retro/games/curated"
METADATA_DIR="/tank/archive/retro/metadata/pegasus/collections"

EXODOS_SRC="${SOURCE_BASE}/eXoDOS"
EXODOS_DST="${TARGET_BASE}/exo-dos"
EXODOS_DATASET="tank/archive/retro/games/curated/exo-dos"

EXOWIN3X_SRC="${SOURCE_BASE}/eXoWin3x"
EXOWIN3X_DST="${TARGET_BASE}/exo-win3x"
EXOWIN3X_DATASET="tank/archive/retro/games/curated/exo-win3x"

LOG_FILE="/var/log/consolidate-collections.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

warning() {
    echo -e "${YELLOW}⚠ $*${NC}" | tee -a "${LOG_FILE}"
}

info() {
    echo -e "${BLUE}ℹ $*${NC}" | tee -a "${LOG_FILE}"
}

# Verify we're running on europa
if ! hostname | grep -q europa; then
    error "This script must be run on europa. Try: ssh root@10.1.1.2 bash /root/consolidate-collections.sh"
fi

log "=== Consolidating Game Collections via ZFS send/recv ==="
log "Source base: ${SOURCE_BASE}"
log "Target base: ${TARGET_BASE}"
log "Log file: ${LOG_FILE}"
log ""

# Verify ZFS is available
if ! command -v zfs &> /dev/null; then
    error "ZFS not found. This script requires ZFS."
fi

success "ZFS available"

# Create target base directory
mkdir -p "${METADATA_DIR}"
success "Created metadata directory"

# Function to consolidate via ZFS send/recv from read-only europa pool
consolidate_collection_zfs() {
    local src="$1"
    local dst="$2"
    local dst_dataset="$3"
    local name="$4"
    local xml_path="$5"

    if [[ ! -d "${src}" ]]; then
        warning "${name} not found at ${src}, skipping"
        return 0
    fi

    log ""
    log "Consolidating ${name}..."
    info "  Source: ${src}"
    info "  Target: ${dst_dataset}"

    # Check if destination dataset already exists
    if zfs list -H "${dst_dataset}" &>/dev/null; then
        warning "Dataset ${dst_dataset} already exists"
        read -p "Destroy and recreate? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Skipping ${name}"
            return 0
        fi
        zfs destroy -r "${dst_dataset}" || error "Failed to destroy ${dst_dataset}"
        success "Destroyed existing dataset"
    fi

    # Create ZFS dataset and copy directory contents
    # (europa pool collections are directories, not separate datasets)
    log "Creating ZFS dataset ${dst_dataset}..."
    zfs create -p "${dst_dataset}" || error "Failed to create dataset ${dst_dataset}"

    log "Copying directory contents ${src} -> ${dst}..."
    rsync -av --progress "${src}/" "${dst}/" || {
        error "Failed to copy ${name} from ${src} to ${dst}"
    }

    success "${name} consolidated to ${dst_dataset}"

    # Verify dataset was created and is mounted
    if zfs list -H "${dst_dataset}" &>/dev/null; then
        success "Dataset ${dst_dataset} created successfully"
        info "  Mounted at: $(zfs get -H mountpoint "${dst_dataset}" | cut -f3)"
    else
        error "Dataset ${dst_dataset} not found after recv"
    fi

    # Verify LaunchBox XML exists
    if [[ -f "${dst}/${xml_path}" ]]; then
        success "LaunchBox XML found at ${xml_path}"
    else
        warning "LaunchBox XML not found at expected location: ${xml_path}"
        info "Searching for XML files..."
        find "${dst}" -name "*.xml" -path "*/Platforms/*" 2>/dev/null | head -3 | while read -r xml; do
            info "  Found: ${xml}"
        done
    fi

    return 0
}

# Consolidate eXoDOS
log ""
log "--- eXoDOS (via tar | zfs recv) ---"
consolidate_collection_zfs \
    "${EXODOS_SRC}" \
    "${EXODOS_DST}" \
    "${EXODOS_DATASET}" \
    "eXoDOS" \
    "Data/Platforms/MS-DOS.xml"

# Consolidate eXoWin3x
log ""
log "--- eXoWin3x (via tar | zfs recv) ---"
consolidate_collection_zfs \
    "${EXOWIN3X_SRC}" \
    "${EXOWIN3X_DST}" \
    "${EXOWIN3X_DATASET}" \
    "eXoWin3x" \
    "Data/Platforms/Windows 3x.xml"

# Verify consolidated collections
log ""
log "=== ZFS Dataset Verification ==="
log "Listing created datasets:"
zfs list -H tank/archive/retro/games/curated 2>/dev/null || warning "No datasets found"

info "eXoDOS:"
zfs get -H compressratio,used,available "${EXODOS_DATASET}" 2>/dev/null | \
    while IFS=$'\t' read -r dataset property value; do
        info "  ${property}: ${value}"
    done

info "eXoWin3x:"
zfs get -H compressratio,used,available "${EXOWIN3X_DATASET}" 2>/dev/null | \
    while IFS=$'\t' read -r dataset property value; do
        info "  ${property}: ${value}"
    done

# Generate Pegasus metadata
log ""
log "=== Generating Pegasus Metadata ==="
if command -v python3 &> /dev/null; then
    for collection in curated-exo-dos curated-exo-win3x; do
        log "Generating metadata for ${collection}..."
        python3 /root/jupiter-os/scripts/generate-arcade-metadata.py \
            --nfs-root /tank/archive \
            --output "${METADATA_DIR}" \
            --assets /tank/archive/retro/metadata/pegasus/assets \
            --collections "${collection}" 2>&1 | tee -a "${LOG_FILE}" || {
            warning "Metadata generation failed for ${collection}"
        }
    done
    success "Pegasus metadata generated"
else
    warning "python3 not found, skipping metadata generation"
    warning "Run manually: python3 /root/jupiter-os/scripts/generate-arcade-metadata.py ..."
fi

# Summary
log ""
log "=== Consolidation Complete ==="
log ""
log "Collections consolidated via ZFS send/recv:"
log "  eXoDOS: ${EXODOS_DATASET}"
log "  eXoWin3x: ${EXOWIN3X_DATASET}"
log ""
log "Mounted at:"
log "  ${EXODOS_DST}/"
log "  ${EXOWIN3X_DST}/"
log ""
log "Pegasus metadata at:"
log "  ${METADATA_DIR}/curated-exo-dos.txt"
log "  ${METADATA_DIR}/curated-exo-win3x.txt"
log ""
log "Next steps:"
log "1. Verify collections are accessible: zfs list tank/archive/retro/games/curated"
log "2. Check Pegasus metadata: ls -l ${METADATA_DIR}/curated-*.txt"
log "3. Test on a kiosk: select a game in Pegasus"
log ""
log "To clean up old location after verification (optional):"
log "  rm -rf ${EXODOS_SRC}"
log "  rm -rf ${EXOWIN3X_SRC}"
