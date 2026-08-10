{
  lib,
  buildGoModule,
}:

# suno-backup — Go daemon that mirrors a Suno account's library (lossless WAV
# masters + the complete per-clip metadata object) into europa's
# tank/archive/suno dataset. Built from the in-tree source alongside this
# default.nix (main.go + go.mod). Consumed by modules/services/suno-backup.nix
# via pkgs.callPackage, and exposed as the flake package `.#suno-backup` so the
# vendorHash can be recomputed standalone.
#
# The daemon is stdlib-only — it has zero non-stdlib dependencies, so the
# vendored-deps set is empty. Bump procedure is the standard buildGoModule one
# (same as modules/core/crush.nix): set vendorHash to lib.fakeHash, build, paste
# the `got:` hash back. If a dependency is ever added, run `go mod tidy` first.
buildGoModule {
  pname = "suno-backup";
  version = "0.1.0";

  src = ./.;

  # The daemon is stdlib-only — zero non-stdlib dependencies — so the vendored
  # deps set is empty, which buildGoModule requires be expressed as null (an
  # empty vendor folder is a build error otherwise). If a dependency is ever
  # added, switch this to lib.fakeHash, build, paste the got: hash (same
  # procedure as modules/core/crush.nix).
  vendorHash = null;

  ldflags = [ "-s" ];

  doCheck = false;

  meta = with lib; {
    description = "Suno account library backup daemon (WAV masters + full metadata) for europa";
    mainProgram = "suno-backup";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
