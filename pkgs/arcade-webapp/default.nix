{
  lib,
  buildGoModule,
  # rev stamps the version from git (arcade remediation W4a / plan §6.F:
  # "a static 0.1.0 cannot identify what is live"). Passed explicitly by
  # every caller — the flake's packages output passes self.rev, the
  # NixOS module passes the fleet-wide overlay attr — because callPackage
  # must not be able to inject a pkgs attr of this name. Empty = a dev
  # checkout; the binary then reports 0.1.0-dev.
  rev ? "",
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
let
  # The version carries the git rev when the caller knows it (flake-built:
  # self.rev of the exact tree; dirty checkouts report 0.1.0-dev). The
  # same string is stamped INTO the binary via -X main.version, so
  # `arcade-webapp -version` and the startup log identify what is live.
  version = if rev == "" then "0.1.0-dev" else "0.1.0-g${lib.strings.substring 0 7 rev}";
in
buildGoModule {
  pname = "arcade-webapp";
  inherit version;

  src = ./.;

  inherit subPackages;

  # modernc.org/sqlite (ADR-0002 D3: pure-Go SQLite driver, no cgo) flipped
  # vendorHash from null to a real hash in Phase 1 via the standard
  # buildGoModule bump procedure.
  vendorHash = "sha256-BAvfNq8jRMtxnNRnCfD4m3N9Yqc7o9dM/v6eVfK0Iag=";

  ldflags = [
    "-s"
    "-X main.version=${version}"
  ];

  doCheck = true;

  meta = with lib; {
    description = "jupiterOS Arcade pipeline webapp (DAT currency, downloads, verify, metadata, launcher DB, curation)";
    mainProgram = "arcade-webapp";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
