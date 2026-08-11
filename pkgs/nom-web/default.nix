{
  lib,
  buildGoModule,
}:

# nom-web — a web port of nix-output-monitor: parses the same
# `--log-format internal-json` stream nom consumes and renders it as a
# browser UI (SSE-pushed, one shared parse per file regardless of viewer
# count). Built from the in-tree source alongside this default.nix (main.go
# + parser.go + session.go + snapshot.go + go.mod + embedded static/).
# Consumed by modules/services/nom-web.nix via pkgs.callPackage, and exposed
# as the flake package `.#nom-web` so the vendorHash can be recomputed
# standalone.
#
# Stdlib-only — zero non-stdlib Go dependencies (SSE instead of WebSocket
# specifically to avoid needing a dependency), so the vendored-deps set is
# empty. Bump procedure is the standard buildGoModule one (same as
# modules/core/crush.nix / pkgs/suno-backup): set vendorHash to
# lib.fakeHash, build, paste the `got:` hash back. If a dependency is ever
# added, run `go mod tidy` first.
buildGoModule {
  pname = "nom-web";
  version = "0.1.0";

  src = ./.;

  vendorHash = null;

  ldflags = [ "-s" ];

  doCheck = true;

  meta = with lib; {
    description = "Web UI for nix's internal-json build logs (nix-output-monitor, for the browser)";
    mainProgram = "nom-web";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
