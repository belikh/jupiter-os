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
#   * Download resume is global on the daemon (--continue=true), so a torrent
#     submitted with the same dir= as its partials/.aria2 control file resumes
#     in place.
#   * seed-time=0 per download keeps the acquired torrent from seeding forever
#     (the daemon global default is 60m) — bulk ROM sets are staged, not seeded.

set -euo pipefail

RPC_HOST="${RPC_HOST:-127.0.0.1}"
RPC_PORT="${RPC_PORT:-6800}"
RPC_SECRET_FILE="${RPC_SECRET_FILE:-/run/secrets/jupiter_aria2_rpc_secret}"

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
  "$CURL" -fsS --max-time 30 -H 'Content-Type: application/json' \
    -d "@$pfile2" "http://${RPC_HOST}:${RPC_PORT}/jsonrpc"
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
    # [token, b64, [], {dir, seed-time, allow-overwrite}] — the empty URIs
    # array is load-bearing (issue #2075), see header.
    params="$(
      "$JQ" -nc --rawfile b64 "$b64file" --arg dir "$dir" \
        '[$b64, [], {dir:$dir, "seed-time":"0", "allow-overwrite":"true"}]'
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
