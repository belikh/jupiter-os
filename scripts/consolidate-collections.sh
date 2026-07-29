#!/bin/bash
# consolidate-collections.sh — Consolidate eXoDOS and eXoWin3x via ZFS send
#
# Strategy: Send full europa/games@b4exodoslinux snapshot, extract needed
# collections to nested datasets, delete staging.
#
# Prerequisites:
# - Script runs ON europa (10.1.1.2)
# - ~4 TB free space on tank/archive pool (worst case: full snapshot + extraction)
# - No active Pegasus/arcade sessions
#
# Usage:
#   ssh root@10.1.1.2 bash /root/consolidate-collections.sh

set -euo pipefail

# Configuration
EUROPA_HOST="10.1.1.2"
SOURCE_SNAPSHOT="europa/games@b4exodoslinux"
TARGET_BASE="/tank/archive/retro/games/curated"
STAGING_DATASET="tank/archive/retro/games/staging-europa-games"
STAGING_MOUNT="/mnt/staging-europa-games"
METADATA_DIR="/tank/archive/retro/metadata/pegasus/collections"

EXODOS_DATASET="tank/archive/retro/games/curated/exo-dos"
EXOWIN3X_DATASET="tank/archive/retro/games/curated/exo-win3x"

LOG_FILE="/var/log/consolidate-collections.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

warning() {
    echo -e "${YELLOW}⚠ $*${NC}" | tee -a "${LOG_FILE}"
}

info() {
    echo -e "${BLUE}ℹ $*${NC}" | tee -a "${LOG_FILE}"
}

# Verify we're on a machine that can receive (tank pool accessible)
if ! zfs list tank &>/dev/null 2>&1; then
    error "tank pool not found. This script must be run on a machine with tank pool access."
fi

log "=== Consolidating Game Collections (eXoDOS, eXoWin3x) ==="
log "Strategy: Send europa/games snapshot → staging → extract collections → delete staging"
log "Source snapshot: ${SOURCE_SNAPSHOT}"
log "Target base: ${TARGET_BASE}"
log "Staging: ${STAGING_DATASET} → ${STAGING_MOUNT}"
log ""

# Verify ZFS is available
command -v zfs &>/dev/null || error "ZFS not found"
success "ZFS available"

mkdir -p "${METADATA_DIR}"
success "Created metadata directory"

# Step 1: Send snapshot from europa to staging dataset
log ""
log "=== Step 1: Receive europa/games snapshot to staging ==="
log "Sending ${SOURCE_SNAPSHOT}..."

# Destroy staging if it exists from a previous failed run
if zfs list -H "${STAGING_DATASET}" &>/dev/null; then
    log "Destroying existing staging dataset..."
    zfs destroy -r "${STAGING_DATASET}" || error "Failed to destroy existing staging"
    success "Staging cleaned up"
fi

# Send snapshot from europa to tank (local if on europa, else remote)
if hostname | grep -q europa; then
    log "Running on europa, using local zfs send"
    zfs send ${SOURCE_SNAPSHOT} | zfs recv -F "${STAGING_DATASET}" || error "Failed to send snapshot"
else
    log "Running remotely, using SSH to europa"
    ssh root@${EUROPA_HOST} "zfs send ${SOURCE_SNAPSHOT}" | zfs recv -F "${STAGING_DATASET}" || {
        error "Failed to send snapshot from europa"
    }
fi

# Verify staging is mounted
STAGING_MOUNT_REAL=$(zfs get -H -o value mountpoint "${STAGING_DATASET}")
log "Staging dataset mounted at: ${STAGING_MOUNT_REAL}"
success "Snapshot received to staging"

# Step 2: Create nested datasets from staging content
log ""
log "=== Step 2: Extract collections to nested datasets ==="

# Helper to extract directory from staging to nested dataset
extract_collection() {
    local src_dir="$1"
    local dst_dataset="$2"
    local name="$3"
    local xml_path="$4"

    if [[ ! -d "${STAGING_MOUNT_REAL}/${src_dir}" ]]; then
        warning "${name} directory not found at ${STAGING_MOUNT_REAL}/${src_dir}"
        return 1
    fi

    log ""
    info "Extracting ${name}..."
    log "  Source: ${STAGING_MOUNT_REAL}/${src_dir}"
    log "  Dataset: ${dst_dataset}"

    # Destroy destination if it exists
    if zfs list -H "${dst_dataset}" &>/dev/null; then
        log "  Destroying existing ${dst_dataset}..."
        zfs destroy -r "${dst_dataset}" || error "Failed to destroy ${dst_dataset}"
    fi

    # Create dataset by tar'ing source directory and piping to zfs recv
    log "  Creating ZFS dataset from directory contents..."
    tar -C "${STAGING_MOUNT_REAL}/${src_dir}" -cf - . | zfs recv -F "${dst_dataset}" || {
        error "Failed to create ${dst_dataset}"
    }

    success "Created ${dst_dataset}"

    # Verify structure
    local dst_mount=$(zfs get -H -o value mountpoint "${dst_dataset}")
    log "  Mounted at: ${dst_mount}"

    if [[ -f "${dst_mount}/${xml_path}" ]]; then
        success "  LaunchBox XML verified: ${xml_path}"
    else
        warning "  LaunchBox XML not found at expected location: ${xml_path}"
    fi

    # Show size
    local size=$(zfs get -H -o value used "${dst_dataset}")
    log "  Dataset size: ${size}"
}

extract_collection "eXoDOS" "${EXODOS_DATASET}" "eXoDOS" "Data/Platforms/MS-DOS.xml"
extract_collection "eXoWin3x" "${EXOWIN3X_DATASET}" "eXoWin3x" "Data/Platforms/Windows 3x.xml"

# Step 3: Verify collections
log ""
log "=== Step 3: Verifying Datasets ==="
log "Created datasets:"
zfs list -r "${TARGET_BASE}" 2>/dev/null || warning "No curated datasets found"

for ds in "${EXODOS_DATASET}" "${EXOWIN3X_DATASET}"; do
    if zfs list -H "${ds}" &>/dev/null; then
        size=$(zfs get -H -o value used "${ds}")
        mount=$(zfs get -H -o value mountpoint "${ds}")
        info "${ds}: ${size} (mounted at ${mount})"
    fi
done

# Step 4: Clean up staging dataset
log ""
log "=== Step 4: Cleaning up staging ==="
log "Destroying ${STAGING_DATASET}..."
zfs destroy -r "${STAGING_DATASET}" || error "Failed to destroy staging dataset"
success "Staging cleaned up"

# Step 5: Generate Pegasus metadata
log ""
log "=== Step 5: Generating Pegasus Metadata ==="

if command -v python3 &>/dev/null; then
    for collection in curated-exo-dos curated-exo-win3x; do
        log "Generating metadata for ${collection}..."
        python3 /root/jupiter-os/scripts/generate-arcade-metadata.py \
            --nfs-root /tank/archive \
            --output "${METADATA_DIR}" \
            --assets /tank/archive/retro/metadata/pegasus/assets \
            --collections "${collection}" 2>&1 | tee -a "${LOG_FILE}" || {
            warning "Metadata generation had issues, but collection is ready"
        }
    done
    success "Pegasus metadata generated"
else
    warning "python3 not found, skipping metadata generation"
fi

# Summary
log ""
log "=== Consolidation Complete ==="
log ""
log "Collections consolidated:"
log "  • eXoDOS → ${EXODOS_DATASET}"
log "  • eXoWin3x → ${EXOWIN3X_DATASET}"
log ""
log "Pegasus metadata:"
log "  • ${METADATA_DIR}/curated-exo-dos.txt"
log "  • ${METADATA_DIR}/curated-exo-win3x.txt"
log ""
log "Next steps:"
log "1. Verify datasets: zfs list -r tank/archive/retro/games/curated"
log "2. Check metadata: ls -lh ${METADATA_DIR}/curated-*.txt"
log "3. Test on kiosk: select a game in Pegasus"
log ""
log "Log: ${LOG_FILE}"
