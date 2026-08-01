#!/usr/bin/env bash
#
# Nix post-build-hook for CI. Enqueues each just-built output for the
# background drainer (scripts/ci/cache-drainer.sh) to `nix copy` into europa's
# store. Does NO network I/O — it only flock-appends $OUT_PATHS to a queue and
# exits, so it can never block nix's build loop. (The pallene build-server
# learned this the hard way on 2026-07-19: an inline push hook burned ~26min
# stalling every build — see modules/services/build-server.nix's pushHook
# comment. Same design here.)
#
# Ported from build-server.nix's pushHook; the drainer swaps `attic push` for
# `nix copy --to ssh://europa`. Nix passes outputs via $OUT_PATHS (space-
# separated), NOT stdin — a prior version read `cat` from stdin and silently
# pushed nothing for 232 consecutive firings (build-server.nix:72-80).
#
# Runs as the nix-daemon user (root) under install-nix-action; the drainer runs
# as the runner user, so the queue/lock files are created world-writable
# (umask 000 + chmod 666) for cross-user access.
set -uo pipefail
umask 000
queue="${QUEUE_FILE:-/tmp/ci-cache-queue.txt}"
lock="${QUEUE_LOCK:-/tmp/ci-cache-queue.lock}"

[ -z "${OUT_PATHS:-}" ] && exit 0

touch "$queue" "$lock"
chmod 666 "$queue" "$lock"
paths="$(printf '%s' "$OUT_PATHS" | tr ' ' '\n')"

exec 9>"$lock"
flock 9
printf '%s\n' "$paths" >>"$queue"
exec 9>&-
exit 0
