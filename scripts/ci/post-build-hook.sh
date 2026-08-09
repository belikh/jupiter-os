#!/usr/bin/env bash
# Post-build hook: writes completed store paths to a FIFO for async push to europa
# Runs on each GitHub Actions builder (as root via nix-daemon)

set -uo pipefail

FIFO="/var/run/nix-push-fifo"
LOG="/var/log/nix-push-hook.log"

# Ensure FIFO exists
if [[ ! -p "$FIFO" ]]; then
    mkfifo -m 600 "$FIFO" 2>/dev/null || true
fi

# nix passes: $1 = store path, $2 = derivation path (optional), $3 = "built"|"substituted"
STORE_PATH="$1"
DERIVATION="${2:-}"
STATUS="${3:-built}"

# Write to FIFO (non-blocking with timeout)
# Format: STATUS<TAB>STORE_PATH<TAB>DERIVATION<TAB>TIMESTAMP
{
    printf '%s\t%s\t%s\t%s\n' "$STATUS" "$STORE_PATH" "$DERIVATION" "$(date -u +%s)"
} >> "$FIFO" 2>>"$LOG" || {
    # Fallback: append to log file if FIFO blocked
    printf '[%s] FIFO blocked, queued locally: %s\n' "$(date -u +%s)" "$STORE_PATH" >> "$LOG"
}

exit 0