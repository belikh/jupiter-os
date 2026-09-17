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
#   2. `nix build .#open-design-daemon .#open-design-web` (or the host
#      toplevel) and copy the reported `pnpmDeps` hashes into the two
#      package derivations.
{
  fetchFromGitHub,
}:
rec {
  version = "0.22.1";
  rev = "2acb7f6f699283622850fe9517c8babf9c869dc7";
  src = fetchFromGitHub {
    owner = "nexu-io";
    repo = "open-design";
    inherit rev;
    hash = "sha256-vMfgmQZTEOxtJuk/9A7QLx9kfCLLWednGCqOmasbQi0=";
  };
}
