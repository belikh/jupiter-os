#!/usr/bin/env bash
#
# After a successful main-branch build: ensure the host's toplevel is in
# europa's store, pin it as a GC root named <host>.<sha>, and rotate to keep
# only the newest N (default 3) main builds per host. Runs on the GHA runner;
# SSHes to europa as jupiter-ci to create the root + rotate.
#
# Roots live in the jupiter-ci-owned per-user gcroots dir
# (modules/core/ci-cache-receiver.nix tmpfiles), so a plain `ln -s` is a valid
# root (no nix-store --add-root / daemon write needed). europa's nix.gc then
# reclaims anything unrooted, so older builds drop out of Harmonia's served
# set automatically. See docs/ci-harmonia-push-runbook.md §retention.
set -euo pipefail

host="${BUILD_HOST:?BUILD_HOST required}"
sha="${BUILD_SHA:?BUILD_SHA required}"
keep="${RETAIN:-3}"
ssh="${EUROPA_SSH:-europa-ci}"

# Resolve the toplevel out path the runner just built. The same store-path
# string is valid on europa once copied (nix paths are content-addressed).
out="$(nix path-info ".#nixosConfigurations.${host}.config.system.build.toplevel")"

# Idempotent safety net: guarantee the pinned target is in europa's store even
# if the drainer lagged behind the hook. (Incremental deps were pushed
# per-package by the drainer; this nails down the one path we root.)
timeout 900 nix copy --to "ssh-ng://$ssh" "$out"

# Pin + rotate on europa as jupiter-ci.
ssh "$ssh" bash -s "$out" "$host" "$sha" "$keep" <<'REMOTE'
  set -euo pipefail
  out="$1"; host="$2"; sha="$3"; keep="$4"
  dir="/nix/var/nix/gcroots/per-user/$(id -un)"
  ln -sfn "$out" "$dir/${host}.${sha}"
  # Keep the newest $keep roots for this host (by mtime); rm the rest, which
  # unroots them so europa's nix.gc can reclaim the closures.
  ls -t "$dir"/${host}.* 2>/dev/null | tail -n +$((keep + 1)) | while read -r r; do
    rm -f -- "$r"
  done
  echo "pinned ${host}.${sha}; $(ls "$dir"/${host}.* 2>/dev/null | wc -l) ${host} root(s) held"
REMOTE
