#!/usr/bin/env bash
# Post-build hook: signs the just-built paths, then opportunistically triggers
# an async full-store push (`nix copy --all`) to europa's binary cache.
# Runs on each GitHub Actions builder (as root via nix-daemon)

set -uo pipefail
set -f  # OUT_PATHS is space-split below; a store path may contain glob chars

LOG="${PUSH_HOOK_LOG:-/var/log/nix-push-hook.log}"

# Nix contract (manual §7.5 "Using the post-build-hook"): the hook is invoked
# with NO positional arguments. The just-built outputs arrive in $OUT_PATHS
# (space-separated) and the derivation in $DRV_PATH. Reading $1 here crashed
# under `set -u` -> exit 1 -> "the build loop exits if the hook program fails",
# aborting the whole distributed build at the first completed derivation and
# leaving every remote builder idle.
OUT_PATHS="${OUT_PATHS:-}"

# The hook only fires after a real build, never after a substitution, so STATUS
# is always "built". This script MUST exit 0 in every path: a non-zero exit
# kills Nix's build loop, and one cache push is never worth aborting a
# 20-machine distributed build for.
[ -z "$OUT_PATHS" ] && exit 0

hook_log() {
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG" 2>/dev/null || true
}

# SIGN every just-built path with the cache secret key before it is pushed:
# europa's nix daemon enforces require-sigs=true (re-enabled 2026-08-17; the
# unsigned-import hole it closed is documented in
# modules/core/ci-cache-receiver.nix), so an unsigned path is rejected by
# `nix copy --to ssh://europa` at drain time — failing the whole run's push
# after 40 minutes of building instead of 4 seconds here. Non-fatal (exit 0
# always) but LOUD: the log line names the exact failure coming.
# HARMONIA_SIGNING_KEY_FILE must point at a `nix store sign` key file
# (<name>:<base64>, exactly as emitted by nix-store --generate-binary-cache-key)
# readable by root — the workflows stage it from
# the HARMONIA_SECRET_KEY secret next to the hook install.
SIGN_KEY_FILE="${HARMONIA_SIGNING_KEY_FILE:-}"
# Resolve nix the way the drain trigger below does: the hook inherits the
# DAEMON's environment (systemd secure_path on Ubuntu runners), where `nix` is
# NOT on PATH — `command -v nix` silently failed here on every run, so nothing
# was ever signed and europa (require-sigs=true) rejected every push.
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

# ---- Async full-store drain --------------------------------------------------
# Instead of queueing individual paths into a FIFO for a separate drainer
# daemon, every invocation just checks whether a full-store push is already
# running: if not, it detaches ONE background `nix copy --to <store> --all`;
# if yes, it exits immediately — the in-flight sweep already covers everything
# currently in the store, and any path built after that sweep started is picked
# up by the next hook invocation's trigger. flock on LOCK_FILE makes this race
# free even when several derivations finish at once: concurrent hooks collapse
# into a single copy, because each spawned child re-asserts the lock
# non-blocking and loses silently if another won. The workflow's final
# `nix copy` of the toplevels remains the authoritative completeness backstop.
#
# Push config lives in PUSH_ENV_FILE (staged root-only by the workflows):
#   NIX_BIN       — absolute nix path (the daemon's secure_path has none)
#   EUROPA_STORE  — e.g. ssh-ng://root@europa or an ssh-config alias
#   NIX_SSHOPTS   — optional; passed through to nix's embedded ssh (-i key etc.)
PUSH_ENV_FILE="${EUROPA_PUSH_ENV_FILE:-/etc/nix/europa-push.env}"
LOCK_FILE="${EUROPA_PUSH_LOCK:-/var/run/nix-copy-all.lock}"

if [ ! -r "$PUSH_ENV_FILE" ]; then
    hook_log "WARNING: no readable push config ($PUSH_ENV_FILE) — not triggering nix copy --all"
    exit 0
fi
# shellcheck disable=SC1090
# set +u around the source: the file is ours (workflow-staged, `bash -n`
# validated), but a hand-edited stray $var must not kill the hook under -u —
# a dead hook aborts nix's whole build loop.
set +u
. "$PUSH_ENV_FILE"
set -u

if [ -z "${NIX_BIN:-}" ] || [ ! -x "$NIX_BIN" ]; then
    hook_log "WARNING: push config lacks executable NIX_BIN — not triggering nix copy --all"
    exit 0
fi
if [ -z "${EUROPA_STORE:-}" ]; then
    hook_log "WARNING: push config lacks EUROPA_STORE — not triggering nix copy --all"
    exit 0
fi
mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
if ! : > "$LOCK_FILE" 2>/dev/null; then
    hook_log "WARNING: cannot create/write lock $LOCK_FILE — not triggering nix copy --all"
    exit 0
fi

if flock -n "$LOCK_FILE" true 2>/dev/null; then
    hook_log "no nix copy running — triggering nix copy --to $EUROPA_STORE --all"
    setsid env \
        EUROPA_PUSH_LOCK="$LOCK_FILE" \
        EUROPA_PUSH_LOG="$LOG" \
        NIX_BIN="$NIX_BIN" \
        EUROPA_STORE="$EUROPA_STORE" \
        NIX_SSHOPTS="${NIX_SSHOPTS:-}" \
        bash -c '
            exec 9>>"$EUROPA_PUSH_LOCK"
            if ! flock -n 9; then exit 0; fi  # lost a spawn race — the winner covers us
            printf "[%s] nix copy --to %s --all started\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$EUROPA_STORE" >> "$EUROPA_PUSH_LOG"
            "$NIX_BIN" copy --to "$EUROPA_STORE" --all >>"$EUROPA_PUSH_LOG" 2>&1
            rc=$?
            printf "[%s] nix copy --all finished rc=%d\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc" >> "$EUROPA_PUSH_LOG"
            exit 0
        ' </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
else
    hook_log "nix copy --all already running — skipping trigger"
fi

exit 0
