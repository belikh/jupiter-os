#!/usr/bin/env bash
# aria2-rpc.sh — submit downloads to a running aria2 JSON-RPC daemon.
#
# The jupiterOS Arcade's ROM acquisition (modules/services/rom-acquire.nix)
# requests its torrent downloads through the fleet aria2 daemon's JSON-RPC
# endpoint (:6800, modules/services/aria2.nix) instead of running a private
# aria2 process. This script is that thin client.
#
# Commands:
#   submit-torrent <torrent> <dir>   add a BitTorrent download; prints the GID
#   tell-active                      list active download GIDs (smoke check)
#   get-global-stat                  print active/waiting/stopped counts
#
# Env (all optional; defaults target the local fleet daemon):
#   RPC_HOST         aria2 JSON-RPC host      (default: 127.0.0.1)
#   RPC_PORT         aria2 JSON-RPC port      (default: 6800)
#   RPC_SECRET_FILE  file holding the rpc-secret token (default:
#                    /run/secrets/jupiter_aria2_rpc_secret)
#
# Notes:
#   * The empty URIs array [] is REQUIRED: aria2.addTorrent IGNORES the
#     options struct unless an (even empty) URIs list is present (aria2 issue
#     #2075). params must be [token, b64, [], {dir: ...}].
#   * Torrent resume is driven per-submission by check-integrity. When a .aria2
#     control file is already present in dir=, aria2's piece state in it is
#     authoritative, so submit passes check-integrity=false and resumes straight
#     from it — no re-hashing of the whole staged tree. Only when the control
#     file was lost does submit use check-integrity=true, which makes aria2
#     SHA-1 hash-verify the existing chunks in dir= and fetch only the
#     missing/corrupt pieces, so partial data still resumes in place.
#     (--continue=true on the daemon is a no-op for BitTorrent; it only applies
#     to HTTP(S)/FTP.)
#   * seed-time=0 per download keeps the acquired torrent from seeding forever
#     (the daemon global default is 60m) — bulk ROM sets are staged, not seeded.

set -euo pipefail

RPC_HOST="${RPC_HOST:-127.0.0.1}"
RPC_PORT="${RPC_PORT:-6800}"
RPC_SECRET_FILE="${RPC_SECRET_FILE:-/run/secrets/jupiter_aria2_rpc_secret}"
# The RPC endpoint shares aria2's single-threaded event loop with all download
# and socket I/O, so under heavy load (many concurrent torrents, big metainfo)
# the daemon can take a long time to answer even a trivial request (observed
# >30s for getVersion, >120s for addTorrent on large sets). --max-time must
# therefore be generous or a busy daemon spuriously aborts a submission.
RPC_MAX_TIME="${RPC_MAX_TIME:-600}"
# How many transport attempts per RPC call. A JSON-RPC error in the body is a
# HARD result and is never retried; only a transport failure (timeout, HTTP
# 5xx, connection reset) triggers a retry, with exponential backoff.
RPC_MAX_RETRIES="${RPC_MAX_RETRIES:-4}"

JQ="${JQ:-jq}"
CURL="${CURL:-curl}"

# Temp files to clean on exit (b64 staging + params materialization). A single
# shared trap avoids the nested-trap overwrite problem of per-call traps.
_tmpfiles=()
die() {
  echo "aria2-rpc: $*" >&2
  exit 1
}
cleanup() {
  rm -f "${_tmpfiles[@]}"
}
trap cleanup EXIT

rpc() { # method, then a JSON params array (without the token)
  local method="$1" params="$2"
  local secret token payload pfile pfile2
  secret="$(cat "$RPC_SECRET_FILE")"
  token="token:${secret}"
  # A large params array (torrent base64) must never reach jq via argv
  # (MAX_ARG_STRLEN), so materialize it to a temp file first — bash args to
  # this function are fine, only the exec'd jq has the limit.
  pfile="$(mktemp)"
  _tmpfiles+=("$pfile")
  printf '%s' "$params" > "$pfile"
  payload="$(
    "$JQ" -nc \
      --arg method "$method" \
      --arg token "$token" \
      --slurpfile params "$pfile" \
      '{jsonrpc:"2.0", id:"jupiter-aria2", method:$method, params:([$token] + $params[0])}'
  )"
  # curl has the same argv limit — hand it the payload via a file (-d @file).
  pfile2="$(mktemp)"
  _tmpfiles+=("$pfile2")
  printf '%s' "$payload" > "$pfile2"
  # Retry loop: the daemon's JSON-RPC runs on the same single-threaded event
  # loop as all download/socket I/O, so under load it can pause for a long
  # time (even >120s on a busy addTorrent). A JSON-RPC error in the body comes
  # back on HTTP 200 so -f does NOT trip on it — those are hard results we
  # intentionally never retry. Only a transport failure (timeout, HTTP >=400,
  # connection reset) triggers a retry, with exponential backoff, so a brief
  # loop stall no longer spurious-drops a whole system's submission.
  local attempt=0 rc
  while :; do
    if "$CURL" -fsS --max-time "$RPC_MAX_TIME" --connect-timeout 10 \
        -H 'Content-Type: application/json' \
        -d "@$pfile2" "http://${RPC_HOST}:${RPC_PORT}/jsonrpc"; then
      return 0
    fi
    rc=$?
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$RPC_MAX_RETRIES" ]; then
      echo "aria2-rpc: ${CURL} failed (curl rc=$rc) after $RPC_MAX_RETRIES attempt(s) for $method" >&2
      return 1
    fi
    echo "aria2-rpc: ${CURL} transient failure (curl rc=$rc) for $method, retry $attempt/$RPC_MAX_RETRIES" >&2
    sleep "$((2 ** attempt))"
  done
}

case "${1:-}" in
  submit-torrent)
    [ "$#" -eq 3 ] || die "usage: aria2-rpc.sh submit-torrent <torrent> <dir>"
    torrent="$2"
    dir="$3"
    [ -f "$torrent" ] || die "torrent not found: $torrent"
    # The base64 of a large .torrent (many-file sets like PS1/Saturn) exceeds
    # MAX_ARG_STRLEN, so it cannot go through --arg (jq would fail to exec
    # with "Argument list too long"). Stage it in a temp file and let jq read
    # it via --rawfile.
    b64file="$(mktemp)"
    _tmpfiles+=("$b64file")
    base64 -w0 < "$torrent" > "$b64file"
    # check-integrity only when the .aria2 control file is missing: a present
    # control file holds authoritative piece state, so re-hashing the whole
    # staged tree would be pure wasted I/O/CPU on the multi-GB bulk sets.
    # (find on a not-yet-created dir yields nothing -> hash-check, the safe
    # default.)
    if [ -n "$(find "$dir" -name '*.aria2' -print -quit 2>/dev/null)" ]; then
      check_integrity="false"
    else
      check_integrity="true"
    fi
    # [token, b64, [], {dir, seed-time, allow-overwrite, check-integrity}] —
    # the empty URIs array is load-bearing (issue #2075), see header.
    params="$(
      "$JQ" -nc --rawfile b64 "$b64file" --arg dir "$dir" --arg check "$check_integrity" \
        '[$b64, [], {dir:$dir, "seed-time":"0", "allow-overwrite":"true", "check-integrity":($check == "true")}]'
    )"
    resp="$(rpc aria2.addTorrent "$params")"
    echo "$resp" | "$JQ" -r '
      if .error then
        error("aria2 error \(.error.code): \(.error.message)")
      else
        .result
      end'
    ;;
  tell-active)
    rpc aria2.tellActive '[]' | "$JQ" -r '
      if .error then
        error("aria2 error \(.error.code): \(.error.message)")
      else
        (.result[]? | "\(.gid)\t\(.bittorrent.info.name // .dir // "")")
      end'
    ;;
  get-global-stat)
    rpc aria2.getGlobalStat '[]' | "$JQ" -r '
      if .error then
        error("aria2 error \(.error.code): \(.error.message)")
      else
        .result | "active=\(.numActive) waiting=\(.numWaiting) stopped=\(.numStopped) stoppedTotal=\(.numStoppedTotal)"
      end'
    ;;
  *)
    die "usage: aria2-rpc.sh {submit-torrent <torrent> <dir> | tell-active | get-global-stat}"
    ;;
esac
