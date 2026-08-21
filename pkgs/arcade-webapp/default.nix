{
  lib,
  buildGoModule,
}:

# arcade-webapp — the jupiterOS Arcade webapp: one NixOS-native app on europa
# owning the whole cartridge-ROM pipeline (DAT currency, aria2 downloads, igir
# verify, Skyscraper metadata, Pegasus launcher-DB generation, curation).
# See docs/adr/0002-arcade-webapp-custom-vs-romm.md (D2: in-tree placement,
# no new flake input) and docs/plans/arcade-webapp-gauntlet.md.
#
# Currently the Phase 0 STUB: placeholder front page + /healthz. Consumed by
# modules/services/arcade-webapp.nix (Phase 1) via pkgs.callPackage, and
# exposed as the flake package `.#arcade-webapp` so the vendorHash can be
# recomputed standalone.
#
# Stdlib-only — zero non-stdlib dependencies (D3's modernc.org/sqlite arrives
# with Phase 1 and will flip vendorHash from null to a real hash via the
# standard buildGoModule bump procedure: lib.fakeHash, build, paste got:).
buildGoModule {
  pname = "arcade-webapp";
  version = "0.1.0";

  src = ./.;

  # Ship only the webapp binary; cmd/fixturegen is the test-corpus bootstrap
  # (go run / make fixture-arcade), not part of the service.
  subPackages = [ "cmd/arcade-webapp" ];

  vendorHash = null;

  ldflags = [ "-s" ];

  doCheck = true;

  meta = with lib; {
    description = "jupiterOS Arcade pipeline webapp (DAT currency, downloads, verify, metadata, launcher DB, curation)";
    mainProgram = "arcade-webapp";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
