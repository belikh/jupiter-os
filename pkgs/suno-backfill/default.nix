{
  lib,
  buildGoModule,
}:

# suno-backfill — one-shot longitudinal re-observation tool: replays a KNOWN
# id list (built for the arXiv 2509.11824 authors' released suno_urls CSV,
# 81,434 songs scraped May–Oct 2024) against Suno's public clip endpoint
# (GET studio-api.prod.suno.com/api/clip/<id>, the same unauthenticated lane
# suno-top's recheck loop rides). Winners-only by owner decision
# (2026-09-19): clips at/above the 100-upvote floor land directly in
# suno.clips + a source='backfill_2024' sighting, so the running daemon's
# recheck loop adopts their growth curves with zero extra code. Below-floor
# and 404 ids are counted and recorded in the tiny suno.backfill_seen
# bookkeeping table (resume only) — the gone-rate and below-floor share are
# logged as summary stats.
#
# Operator tool, not a service — no host enables it in environmentPackages;
# build on demand (`nix build github:belikh/jupiter-os#suno-backfill`) and run
# on callisto with SUNO_BACKFILL_DATABASE_URL from the suno_database_url sops
# secret. Same vendored-dep pattern as pkgs/suno-top: lib/pq carried in-tree
# in vendor/, vendorHash = null, fully offline builds.
buildGoModule {
  pname = "suno-backfill";
  version = "0.1.0";

  src = ./.;

  vendorHash = null; # vendor/ is in-tree (see comment above)

  ldflags = [ "-s" ];

  doCheck = false;

  meta = with lib; {
    description = "One-shot longitudinal re-scrape of known Suno ids into fleet Postgres (winners into suno.clips, bookkeeping in suno.backfill_seen)";
    mainProgram = "suno-backfill";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
