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
  # release. Version follows package.json, as at the previous pin. Bumped to
  # the 2026-10-08 rev: the workspace manifests (root/pnpm-workspace/apps
  # daemon+web) are byte-identical to the previous pin, so the vendored
  # pnpm-lock.yaml and the pnpmDeps hashes in open-design-{patched,daemon,web}
  # remain valid — no lockfile regen was needed.
  version = "0.23.1";
  rev = "e38462fd50ef8c911c50acc9ccd4b11186655ed9";
  src = fetchFromGitHub {
    owner = "nexu-io";
    repo = "open-design";
    inherit rev;
    hash = "sha256-3IZ2P5maXIce4zxFo532HjByBPdon1v9JMnlODdsGmA=";
  };
}
