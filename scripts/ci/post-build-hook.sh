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
# Logs are written directly to europa via SSH so they persist and are observable.
set -uo pipefail

# Timeout for each synchronous nix copy (seconds). Large bootstrap packages
# (gcc ~500MB) can take 60-120s over WireGuard; 180s provides margin.
COPY_TIMEOUT="${COPY_TIMEOUT:-180}"

queue="${QUEUE_FILE:-/tmp/ci-cache-queue.txt}"
lock="${QUEUE_LOCK:-/tmp/ci-cache-queue.lock}"
ssh_target="ssh-ng://europa-ci"
ssh_host="europa-ci"
log_path="/var/log/jupiter-ci/post-build-hook.log"

[ -z "${OUT_PATHS:-}" ] && exit 0

# Ensure queue/lock exist and are world-writable for cross-user access (drainer runs as runner user)
touch "$queue" "$lock"
chmod 666 "$queue" "$lock"

# Log to europa via SSH (uses ControlMaster from CI workflow)
log_to_europa() {
  local msg="$1"
  ssh -o ControlPath="/root/.ssh/controlmasters/%r@%h:%p" "$ssh_host" \
    "mkdir -p /var/log/jupiter-ci && echo \"$msg\" >> $log_path" 2>/dev/null || true
}

# Use full path to nix since hook runs as root (nix-daemon) without user PATH
NIX_BIN="/nix/var/nix/profiles/default/bin/nix"

paths="$(printf '%s' "$OUT_PATHS" | tr ' ' '\n')"

# Process each output path: try synchronous push first, fall back to queue on failure
while IFS= read -r path; do
  [ -z "$path" ] && continue

  log_to_europa "[post-build-hook $(date -u +%H:%M:%S)] ===== START processing $path ====="
  
  # Capture full output of nix copy (stdout and stderr separately)
  log_to_europa "[post-build-hook $(date -u +%H:%M:%S)] running: timeout $COPY_TIMEOUT $NIX_BIN copy --to $ssh_target $path"
  copy_stderr=$(mktemp)
  copy_stdout=$(mktemp)
  timeout "$COPY_TIMEOUT" "$NIX_BIN" copy --debug --to "$ssh_target" "$path" >"$copy_stdout" 2>"$copy_stderr"
  copy_rc=$?
  
  # Log stdout
  if [ -s "$copy_stdout" ]; then
    while IFS= read -r line; do
      log_to_europa "[post-build-hook $(date -u +%H:%M:%S)] nix-copy-out: $line"
    done <"$copy_stdout"
  else
    log_to_europa "[post-build-hook $(date -u +%H:%M:%S)] nix-copy-out: (empty)"
  fi
  
  # Log stderr
  if [ -s "$copy_stderr" ]; then
    while IFS= read -r line; do
      log_to_europa "[post-build-hook $(date -u +%H:%M:%S)] nix-copy-err: $line"
    done <"$copy_stderr"
  else
    log_to_europa "[post-build-hook $(date -u +%H:%M:%S)] nix-copy-err: (empty)"
  fi
  
  rm -f "$copy_stdout" "$copy_stderr"
  
  log_to_europa "[post-build-hook $(date -u +%H:%M:%S)] nix copy exited with rc=$copy_rc"

  if [ $copy_rc -eq 0 ]; then
    log_to_europa "[post-build-hook $(date -u +%H:%M:%S)] SUCCESS: pushed $path synchronously"
    log_to_europa "[post-build-hook $(date -u +%H:%M:%S)] ===== END processing $path (SUCCESS) ====="
    continue
  fi

  # Determine failure reason
  failure_reason="unknown"
  if [ $copy_rc -eq 124 ]; then
    failure_reason="timeout (${COPY_TIMEOUT}s)"
  elif [ $copy_rc -eq 137 ]; then
    failure_reason="SIGKILL (OOM or timeout)"
  elif [ $copy_rc -eq 255 ]; then
    failure_reason="SSH connection failed"
  elif [ $copy_rc -eq 127 ]; then
    failure_reason="nix binary not found (PATH issue)"
  fi
  
  log_to_europa "[post-build-hook $(date -u +%H:%M:%S)] FAILURE: synchronous push failed for $path (rc=$copy_rc, reason: $failure_reason), queueing for drainer"
  log_to_europa "[post-build-hook $(date -u +%H:%M:%S)] ===== END processing $path (FAILED) ====="

  # Fallback: append to queue for background drainer
  exec 9>"$lock"
  flock 9
  printf '%s\n' "$path" >>"$queue"
  exec 9>&-
done <<<"$paths"

exit 0