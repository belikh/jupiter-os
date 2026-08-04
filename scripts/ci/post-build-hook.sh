#!/usr/bin/env bash
#
# Nix post-build-hook for CI. Appends each just-built output path to the
# async queue for the background drainer. Returns immediately — does NOT
# push to europa. The drainer (cache-drainer.sh) handles all pushing and
# logging.
#
# Runs as the nix-daemon user (root) under install-nix-action.
set -uo pipefail

# Local log file for debugging
LOCAL_LOG="/tmp/post-build-hook-local.log"
echo "[$(date -u +%H:%M:%S)] post-build-hook START, OUT_PATHS='$OUT_PATHS'" >>"$LOCAL_LOG"

queue="${QUEUE_FILE:-/tmp/ci-cache-queue.txt}"
lock="${QUEUE_LOCK:-/tmp/ci-cache-queue.lock}"

[ -z "${OUT_PATHS:-}" ] && { echo "[$(date -u +%H:%M:%S)] OUT_PATHS empty, exiting" >>"$LOCAL_LOG"; exit 0; }

echo "[$(date -u +%H:%M:%S)] Enqueueing paths: $OUT_PATHS" >>"$LOCAL_LOG"

# Ensure queue/lock exist and are world-writable for cross-user access (drainer runs as runner user)
touch "$queue" "$lock"
chmod 666 "$queue" "$lock"

paths="$(printf '%s' "$OUT_PATHS" | tr ' ' '\n')"

# Append each path to queue
while IFS= read -r path; do
  [ -z "$path" ] && continue
  exec 9>"$lock"
  flock 9
  printf '%s\n' "$path" >>"$queue"
  exec 9>&-
done <<<"$paths"

echo "[$(date -u +%H:%M:%S)] post-build-hook END" >>"$LOCAL_LOG"
exit 0