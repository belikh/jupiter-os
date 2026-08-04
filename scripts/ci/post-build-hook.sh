#!/usr/bin/env bash
#
# Nix post-build-hook for CI. Pushes each just-built output to europa's store
# SYNCHRONOUSLY via `nix copy --to ssh-ng://europa-ci` using a persistent SSH
# ControlMaster connection (established in CI workflow). Falls back to queueing
# for the background drainer if the synchronous push fails or times out.
#
# This guarantees that every built package (including bootstrap tools like gcc,
# binutils, xgcc) is durably on europa BEFORE the hook returns, so CI
# cancellation at ANY POINT loses zero work — the next run resumes from the
# last successfully pushed package.
#
# Runs as the nix-daemon user (root) under install-nix-action. The SSH
# ControlMaster socket at /root/.ssh/controlmasters/ is owned by root.
set -uo pipefail

# Timeout for each synchronous nix copy (seconds). Large bootstrap packages
# (gcc ~500MB) can take 60-120s over WireGuard; 180s provides margin.
COPY_TIMEOUT="${COPY_TIMEOUT:-180}"

queue="${QUEUE_FILE:-/tmp/ci-cache-queue.txt}"
lock="${QUEUE_LOCK:-/tmp/ci-cache-queue.lock}"
ssh_target="ssh-ng://europa-ci"

[ -z "${OUT_PATHS:-}" ] && exit 0

# Ensure queue/lock exist and are world-writable for cross-user access (drainer runs as runner user)
touch "$queue" "$lock"
chmod 666 "$queue" "$lock"

paths="$(printf '%s' "$OUT_PATHS" | tr ' ' '\n')"

# Process each output path: try synchronous push first, fall back to queue on failure
while IFS= read -r path; do
  [ -z "$path" ] && continue

  # Synchronous push with timeout. Uses root's SSH config with ControlMaster
  # for fast connection reuse (avoids ~26min stall from per-push SSH handshake).
  if timeout "$COPY_TIMEOUT" nix copy --to "$ssh_target" "$path" 2>&1; then
    echo "[post-build-hook $(date -u +%H:%M:%S)] pushed $path synchronously"
    continue
  fi

  rc=$?
  echo "[post-build-hook $(date -u +%H:%M:%S)] synchronous push failed for $path (rc=$rc), queueing for drainer" >&2

  # Fallback: append to queue for background drainer
  exec 9>"$lock"
  flock 9
  printf '%s\n' "$path" >>"$queue"
  exec 9>&-
done <<<"$paths"

exit 0
