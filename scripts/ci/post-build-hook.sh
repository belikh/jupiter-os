#!/usr/bin/env bash
# Post-build hook: writes completed store paths to a FIFO for async push to europa
# Runs on each GitHub Actions builder (as root via nix-daemon)

set -uo pipefail
set -f  # OUT_PATHS is space-split below; a store path may contain glob chars

FIFO="/var/run/nix-push-fifo"
LOG="/var/log/nix-push-hook.log"

# Ensure FIFO exists. Mode 0666: the hook runs as root (via nix-daemon) but the
# cache-drainer runs as the runner user on the distributed builders, so the
# FIFO must be readable/writable by both — mode 0600 would let root write a
# line the runner drainer could never read.
if [[ ! -p "$FIFO" ]]; then
    mkfifo -m 666 "$FIFO" 2>/dev/null || true
fi

# Nix contract (manual §7.5 "Using the post-build-hook"): the hook is invoked
# with NO positional arguments. The just-built outputs arrive in $OUT_PATHS
# (space-separated) and the derivation in $DRV_PATH. Reading $1 here crashed
# under `set -u` -> exit 1 -> "the build loop exits if the hook program fails",
# aborting the whole distributed build at the first completed derivation and
# leaving every remote builder idle.
OUT_PATHS="${OUT_PATHS:-}"
DRV_PATH="${DRV_PATH:-}"

# The hook only fires after a real build, never after a substitution, so STATUS
# is always "built". This script MUST exit 0 in every path: a non-zero exit
# kills Nix's build loop, and one cache push is never worth aborting a
# 20-machine distributed build for.
[ -z "$OUT_PATHS" ] && exit 0

# Format per output: STATUS<TAB>STORE_PATH<TAB>DERIVATION<TAB>TIMESTAMP
ts="$(date -u +%s)"
for STORE_PATH in $OUT_PATHS; do
    {
        printf '%s\t%s\t%s\t%s\n' "built" "$STORE_PATH" "$DRV_PATH" "$ts"
    } >> "$FIFO" 2>>"$LOG" || {
        # Fallback: append to log file if FIFO blocked
        printf '[%s] FIFO blocked, queued locally: %s\n' "$(date -u +%s)" "$STORE_PATH" >> "$LOG"
    }
done

exit 0