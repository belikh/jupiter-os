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

# Cumulative count of paths enqueued into the FIFO, consumed by cache-drainer.sh
# as the denominator for its progress/backlog math. A FIFO exposes no depth, so
# without this the drainer can only count what it has already READ — which equals
# what it has pushed +/- one in flight — and its "progress %" pins at 99-100%
# regardless of how deep the real backlog is. Bumped atomically (flock) once per
# hook invocation, AFTER the writes land in the FIFO, so the drainer's count
# never includes paths that haven't actually entered the pipe (a FIFO-blocked
# path that fell back to $LOG is deliberately NOT counted). Root writes; the
# drainer (root on the coordinator, runner on distributed builders) only reads.
ENQUEUE_CNT="${ENQUEUE_CNT:-/var/run/nix-push-enqueued}"
bump_enqueue() {
    local n="$1"
    (
        flock 9
        local c=0; [ -f "$ENQUEUE_CNT" ] && c=$(<"$ENQUEUE_CNT")
        echo $((c + n)) > "$ENQUEUE_CNT"
    ) 9>"$ENQUEUE_CNT.lock"
}

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

# SIGN every just-built path with the cache secret key before it is queued:
# europa's nix daemon enforces require-sigs=true (re-enabled 2026-08-17; the
# unsigned-import hole it closed is documented in
# modules/core/ci-cache-receiver.nix), so an unsigned path is rejected by
# `nix copy --to ssh://europa` at drain time — failing the whole run's push
# after 40 minutes of building instead of 4 seconds here. Non-fatal (exit 0
# always) but LOUD: the log line names the exact failure coming.
# HARMONIA_SIGNING_KEY_FILE must point at a `nix store sign` key file
# (secret-key:<name>:<base32>) readable by root — the workflows stage it from
# the HARMONIA_SECRET_KEY secret next to the hook install.
SIGN_KEY_FILE="${HARMONIA_SIGNING_KEY_FILE:-}"
# Resolve nix the way cache-drainer.sh does: the hook inherits the DAEMON's
# environment (systemd secure_path on Ubuntu runners), where `nix` is NOT on
# PATH — `command -v nix` silently failed here on every run, so nothing was
# ever signed and europa (require-sigs=true) rejected every push.
NIX_HOOK="${NIX_BIN:-}"
[ -z "$NIX_HOOK" ] && NIX_HOOK="$(command -v nix 2>/dev/null || true)"
[ -z "$NIX_HOOK" ] && [ -x /nix/var/nix/profiles/default/bin/nix ] && NIX_HOOK=/nix/var/nix/profiles/default/bin/nix
if [ -n "$NIX_HOOK" ] && [ -x "$NIX_HOOK" ] && [ -n "$SIGN_KEY_FILE" ] && [ -r "$SIGN_KEY_FILE" ]; then
    # shellcheck disable=SC2086  # OUT_PATHS is deliberately space-split (set -f above)
    "$NIX_HOOK" store sign --key-file "$SIGN_KEY_FILE" $OUT_PATHS 2>>"$LOG" \
        || printf '[%s] WARNING: nix store sign failed — europa (require-sigs=true) will reject these paths at push time\n' "$(date -u +%s)" >> "$LOG"
else
    printf '[%s] WARNING: no usable nix (%s) or no readable signing key (%s) — europa (require-sigs=true) will reject these paths at push time\n' \
        "$(date -u +%s)" "${NIX_HOOK:-unset}" "${SIGN_KEY_FILE:-unset}" >> "$LOG"
fi

# Format per output: STATUS<TAB>STORE_PATH<TAB>DERIVATION<TAB>TIMESTAMP.
# Count only paths that actually entered the FIFO — keeps the drainer's
# enqueued/pending honest (a fallback'd path never reaches it).
ts="$(date -u +%s)"
written=0
for STORE_PATH in $OUT_PATHS; do
    if printf '%s\t%s\t%s\t%s\n' "built" "$STORE_PATH" "$DRV_PATH" "$ts" >> "$FIFO" 2>>"$LOG"; then
        written=$((written + 1))
    else
        # Fallback: append to log file if FIFO blocked
        printf '[%s] FIFO blocked, queued locally: %s\n' "$(date -u +%s)" "$STORE_PATH" >> "$LOG"
    fi
done
[ "$written" -gt 0 ] && bump_enqueue "$written"

exit 0