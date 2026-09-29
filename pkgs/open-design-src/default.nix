# Upstream OpenDesign source pin.
#
# Upstream retired its official Nix distribution on 2026-08-31
# (nexu-io/open-design@49cc5105 removed flake.nix and nix/) — there is no
# flake to follow any more, so jupiter-os vendors the packaging it needs:
#
#   modules/services/open-design-*.nix   (vendored NixOS module)
#   pkgs/open-design-{src,patched,daemon,web}
#
# Bump `rev`, `version` and the `src` hash together. Then:
#   1. regenerate pkgs/open-design-patched/pnpm-lock.yaml against the new
#      source, with the better-sqlite3 13.0.3 bump applied to
#      apps/daemon/package.json (see the README-style comments in that
#      directory's default.nix);
#   2. rebuild the two packages through the host wiring and copy the
#      reported `pnpmDeps` hashes into the two package derivations. They are
#      not flake outputs — evaluate the host toplevel
#      (`nix build .#nixosConfigurations.callisto.config.system.build.toplevel`)
#      or callPackage them directly with the same arguments
#      (openDesignPackagesModule in flake.nix is the reference wiring).
{
  fetchFromGitHub,
}:
rec {
  # Package.json at the pin reads 0.23.1; upstream does not re-bump it per
  # release, and the newest release tag at/under this rev is
  # open-design-v0.24.1 (its changelog commit is an ancestor of this rev,
  # so that release's content is included). Version follows package.json,
  # as at the previous pin.
  version = "0.23.1";
  rev = "64710082d02c041da47bf8c6d6c5316b36b28b22";
  src = fetchFromGitHub {
    owner = "nexu-io";
    repo = "open-design";
    inherit rev;
    hash = "sha256-Z5hToAuGFDCRJyWucHZsCpKp3at/VmzQPbAl9FVzWfY=";
  };
}
