#!/bin/bash
# download-exowin9x.sh — Download eXoWin9x torrent to /tank/archive/retro/downloads
#
# The torrent can be obtained from: https://www.retro-exo.com/win9x.html
# This script runs aria2c in the background and logs to /var/log/exowin9x-download.log
#
# Usage:
#   ssh root@10.1.1.2 bash /root/jupiter-os/scripts/download-exowin9x.sh /path/to/eXoWin9x_Vol1_v*.torrent

set -euo pipefail

TORRENT_FILE="${1:-}"
if [[ -z "${TORRENT_FILE}" ]]; then
    echo "Usage: $0 <path-to-torrent-file>"
    echo ""
    echo "Example:"
    echo "  $0 /root/eXoWin9x_Vol1_v1.0.torrent"
    exit 1
fi

if [[ ! -f "${TORRENT_FILE}" ]]; then
    echo "ERROR: Torrent file not found: ${TORRENT_FILE}"
    exit 1
fi

# Configuration
DOWNLOAD_DIR="/tank/archive/retro/downloads"
LOG_FILE="/var/log/exowin9x-download.log"
ARIA2_CONF="/tmp/aria2-exowin9x.conf"

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

log "=== eXoWin9x Torrent Download ==="
log "Torrent: ${TORRENT_FILE}"
log "Download to: ${DOWNLOAD_DIR}"
log "Log: ${LOG_FILE}"

# Verify aria2c is available
command -v aria2c &>/dev/null || error "aria2c not found. Install with: nix-shell -p aria2"
success "aria2c available"

# Create download directory
mkdir -p "${DOWNLOAD_DIR}"
success "Download directory ready"

# Create aria2c config
cat > "${ARIA2_CONF}" << 'EOF'
dir=/tank/archive/retro/downloads
max-concurrent-downloads=2
max-connection-per-server=8
split=8
min-split-size=10M
continue=true
disk-cache=64M
file-allocation=prealloc
enable-dht=true
enable-dht6=false
enable-peer-exchange=true
listen-port=6881-6889
seed-time=0
seed-ratio=0.1
EOF

log ""
log "Starting aria2c in background..."
log "Command: aria2c -c --conf-path=${ARIA2_CONF} --log-level=info --log=${LOG_FILE} ${TORRENT_FILE}"

# Start aria2c in background, redirecting output to log
aria2c \
    -c \
    --conf-path="${ARIA2_CONF}" \
    --log-level=info \
    --log="${LOG_FILE}" \
    "${TORRENT_FILE}" &

PID=$!
log "aria2c started with PID ${PID}"
success "Download started in background"

log ""
log "Monitor progress:"
log "  tail -f ${LOG_FILE}"
log ""
log "Check downloaded files:"
log "  ls -lh ${DOWNLOAD_DIR}/"
log ""
log "When complete, consolidate with:"
log "  bash /root/jupiter-os/scripts/setup-exowin9x.sh ${DOWNLOAD_DIR}/eXoWin9x_Vol1_v*.7z"
