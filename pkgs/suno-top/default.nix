{
  lib,
  buildGoModule,
}:

# suno-top — Go daemon that harvests Suno's PUBLIC catalogue into the fleet
# Postgres (callisto, db `jupiter`, schema `suno`): every unique clip at or
# above an upvote floor, with its complete object (prompt/tags/counts) plus an
# append-only sighting log that turns early snapshots into play-count growth
# curves. Four credential-free discovery lanes feed it: the anonymous trending
# feed, a breadth-first crawl of public creator profiles, a public tag search
# (POST /api/search/ tag_song, winners-first, seeded from the styles sitemap)
# and public playlists (ids harvested from profile responses, editorial
# indexes and playlist owners). Companion to pkgs/suno-backup (which mirrors
# our own library); this one vacuums the public winners — all endpoints used
# are verified unauthenticated. Built from the in-tree source alongside this
# default.nix (main.go + main_test.go + go.mod + vendor/). Consumed by
# modules/services/suno-top.nix via pkgs.callPackage, and exposed standalone
# via the flake so `nix build .#suno-top` verifies the source.
#
# Unlike suno-backup this has ONE vendored dependency (github.com/lib/pq for
# the fleet Postgres), carried as an in-tree vendor/ directory. With vendor/
# present, buildGoModule requires vendorHash = null — the vendored deps are
# used as-is (reproducibility enforced by the git-tracked tree itself, and
# builds run fully offline). If deps ever change: go mod tidy && go mod
# vendor, keep vendorHash null, re-stage vendor/.
buildGoModule {
  pname = "suno-top";
  version = "0.3.0";

  src = ./.;

  vendorHash = null; # vendor/ is in-tree (see comment above)

  ldflags = [ "-s" ];

  doCheck = true; # main_test.go is pure (no network, vendored deps)

  meta = with lib; {
    description = "Public Suno trending-feed harvester into fleet Postgres (schema suno)";
    mainProgram = "suno-top";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
