#!/bin/bash
# consolidate-collections.sh — Move eXoDOS and eXoWin3x from /mnt/europa/games to /tank/archive
#
# This script consolidates existing game collections from the legacy location
# (/mnt/europa/games) to the new ZFS-backed archive location (/tank/archive/retro/games/curated).
#
# Prerequisites:
# - Script runs ON europa (10.1.1.2)
# - ~1 TB free space on /tank/archive/retro/games
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

EXOWIN3X_SRC="${SOURCE_BASE}/eXoWin3x"
EXOWIN3X_DST="${TARGET_BASE}/exo-win3x"

LOG_FILE="/var/log/consolidate-collections.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Verify we're running on europa
if ! hostname | grep -q europa; then
    error "This script must be run on europa. Try: ssh root@10.1.1.2 bash /root/consolidate-collections.sh"
fi

log "=== Consolidating Game Collections ==="
log "Source base: ${SOURCE_BASE}"
log "Target base: ${TARGET_BASE}"
log "Log file: ${LOG_FILE}"
log ""

# Create target directories
mkdir -p "${TARGET_BASE}" "${METADATA_DIR}"
success "Created target directories"

# Function to consolidate a collection
consolidate_collection() {
    local src="$1"
    local dst="$2"
    local name="$3"
    local xml_path="$4"

    if [[ ! -d "${src}" ]]; then
        warning "${name} not found at ${src}, skipping"
        return 0
    fi

    if [[ -d "${dst}" ]]; then
        warning "${name} already exists at ${dst}"
        read -p "Overwrite? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Skipping ${name}"
            return 0
        fi
        rm -rf "${dst}"
    fi

    log "Consolidating ${name}..."
    log "  Source: ${src} ($(du -sh "${src}" | cut -f1))"
    log "  This will take 30-60 minutes (copying ~$(($(du -sk "${src}" | cut -f1) / 1024 / 1024)) GB)..."

    # Copy recursively (europa pool is read-only, so can't hard-link)
    # Use rsync for better progress reporting and resume capability
    if command -v rsync &> /dev/null; then
        rsync -av --progress "${src}/" "${dst}/" || {
            error "Failed to copy ${name} from ${src} to ${dst}"
        }
    else
        # Fallback to cp if rsync not available
        log "rsync not available, using cp (no progress reporting)..."
        cp -r "${src}" "${dst}" || {
            error "Failed to copy ${name} from ${src} to ${dst}"
        }
    fi

    success "${name} consolidated to ${dst}"

    # Verify LaunchBox XML exists
    if [[ -f "${dst}/${xml_path}" ]]; then
        success "LaunchBox XML found at ${xml_path}"
    else
        warning "LaunchBox XML not found at expected location: ${xml_path}"
        warning "Searching for XML files..."
        find "${dst}" -name "*.xml" -path "*/Platforms/*" | head -3 | while read -r xml; do
            warning "  Found: ${xml}"
        done
    fi

    return 0
}

# Consolidate eXoDOS
log ""
log "--- eXoDOS ---"
consolidate_collection \
    "${EXODOS_SRC}" \
    "${EXODOS_DST}" \
    "eXoDOS" \
    "Data/Platforms/MS-DOS.xml"

# Consolidate eXoWin3x
log ""
log "--- eXoWin3x ---"
consolidate_collection \
    "${EXOWIN3X_SRC}" \
    "${EXOWIN3X_DST}" \
    "eXoWin3x" \
    "Data/Platforms/Windows 3x.xml"

# Verify consolidated collections
log ""
log "--- Verification ---"
log "eXoDOS:"
du -sh "${EXODOS_DST}" 2>/dev/null || warning "eXoDOS target not accessible"
log "eXoWin3x:"
du -sh "${EXOWIN3X_DST}" 2>/dev/null || warning "eXoWin3x target not accessible"

# Generate Pegasus metadata
log ""
log "--- Generating Pegasus Metadata ---"
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
log "Collections are now at:"
log "  eXoDOS: ${EXODOS_DST}/"
log "  eXoWin3x: ${EXOWIN3X_DST}/"
log ""
log "Pegasus metadata at:"
log "  ${METADATA_DIR}/curated-exo-dos.txt"
log "  ${METADATA_DIR}/curated-exo-win3x.txt"
log ""
log "Next steps:"
log "1. Verify collections are accessible: ls ${EXODOS_DST}/Games | head"
log "2. Check Pegasus metadata: cat ${METADATA_DIR}/curated-exo-dos.txt | head -20"
log "3. Test on a kiosk: select a game in Pegasus"
log ""
log "To clean up old location after verification (optional):"
log "  rm -rf ${EXODOS_SRC}"
log "  rm -rf ${EXOWIN3X_SRC}"
