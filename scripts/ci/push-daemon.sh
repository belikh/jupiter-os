#!/usr/bin/env bash
# Async push daemon: reads completed paths from FIFO and streams them to europa
# Runs on each GitHub Actions builder as a background process

set -uo pipefail

FIFO="/var/run/nix-push-fifo"
LOG="/var/log/nix-push-daemon.log"
EUROPA_HOST="europa-build"
EUROPA_USER="root"
MAX_CONCURRENT=2  # Limit concurrent nix copy processes per builder

# Ensure FIFO exists
[[ -p "$FIFO" ]] || mkfifo -m 600 "$FIFO"

# Track background PIDs for concurrency control
declare -A COPY_PIDS
COPY_COUNT=0

cleanup() {
    echo "[$(date -u +%s)] Daemon shutting down, waiting for ${#COPY_PIDS[@]} copies..." >> "$LOG"
    for pid in "${COPY_PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    exit 0
}
trap cleanup SIGTERM SIGINT EXIT

echo "[$(date -u +%s)] Push daemon started, reading from $FIFO" >> "$LOG"

# Read from FIFO line by line
while IFS=$'\t' read -r STATUS STORE_PATH DERIVATION TIMESTAMP; do
    [[ -z "$STORE_PATH" ]] && continue

    # Throttle: wait if too many concurrent copies
    while [[ $COPY_COUNT -ge $MAX_CONCURRENT ]]; do
        for pid in "${!COPY_PIDS[@]}"; do
            if ! kill -0 "$pid" 2>/dev/null; then
                wait "$pid" 2>/dev/null || true
                unset COPY_PIDS[$pid]
                COPY_COUNT=$((COPY_COUNT - 1))
            fi
        done
        [[ $COPY_COUNT -ge $MAX_CONCURRENT ]] && sleep 0.5
    done

    # Launch async nix copy
    {
        echo "[$(date -u +%s)] Pushing $STORE_PATH to $EUROPA_HOST..." >> "$LOG"
        if nix copy --to "ssh-ng://$EUROPA_USER@$EUROPA_HOST?ssh-options=-o Ciphers=chacha20-poly1305@openssh.com -o MACs=hmac-sha2-256-etm@openssh.com -o Compression=no" "$STORE_PATH" 2>>"$LOG"; then
            echo "[$(date -u +%s)] Pushed OK: $STORE_PATH" >> "$LOG"
        else
            echo "[$(date -u +%s)] PUSH FAILED: $STORE_PATH" >> "$LOG"
        fi
    } &
    COPY_PIDS[$!]=$!
    COPY_COUNT=$((COPY_COUNT + 1))

done < "$FIFO"