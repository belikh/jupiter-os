{
  lib,
  buildGoModule,
  subPackages ? [ "cmd/arcade-webapp" ],
}:

# arcade-webapp — the jupiterOS Arcade webapp: one NixOS-native app on europa
# owning the whole cartridge-ROM pipeline (DAT currency, aria2 downloads, igir
# verify, Skyscraper metadata, Pegasus launcher-DB generation, curation).
# See docs/adr/0002-arcade-webapp-custom-vs-romm.md (D2: in-tree placement,
# no new flake input) and docs/plans/arcade-webapp-gauntlet.md.
#
# Consumed by modules/services/arcade-webapp.nix via pkgs.callPackage, and
# exposed as the flake package `.#arcade-webapp` so the vendorHash can be
# recomputed standalone.
#
# subPackages is a parameter so the VM test host (tests/hosts/
# arcade-webapp-vm.nix) can build cmd/fixturegen from this same source to
# materialize its deterministic fixture tree — the flake package itself
# ships only the webapp binary.
buildGoModule {
  pname = "arcade-webapp";
  version = "0.1.0";

  src = ./.;

  inherit subPackages;

  # modernc.org/sqlite (ADR-0002 D3: pure-Go SQLite driver, no cgo) flipped
  # vendorHash from null to a real hash in Phase 1 via the standard
  # buildGoModule bump procedure.
  vendorHash = "sha256-BAvfNq8jRMtxnNRnCfD4m3N9Yqc7o9dM/v6eVfK0Iag=";

  ldflags = [ "-s" ];

  doCheck = true;

  meta = with lib; {
    description = "jupiterOS Arcade pipeline webapp (DAT currency, downloads, verify, metadata, launcher DB, curation)";
    mainProgram = "arcade-webapp";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
