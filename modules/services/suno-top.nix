{
  config,
  lib,
  pkgs,
  ...
}:

# Public Suno trending harvester (fleet Postgres consumer).
#
# Always-on Go service (pkgs/suno-top, built via pkgs.callPackage) that polls
# Suno's PUBLIC trending feed and walks PUBLIC creator profiles, accumulating
# every unique qualifying clip into the fleet Postgres (db `jupiter`, schema
# `suno`, DDL applied by the daemon on first connect — same pattern as the
# procurement stack). Each clip is stored with its complete object
# (prompts/tags/counts) plus an append-only sighting log capturing play_count
# over time AND the clip's rank in the trending rotation. Only clips at or
# above `minUpvotes` are stored (default 100). Purpose: a queryable dataset of
# the public winners for hit-model research and prompt-style distributions
# (cf. pkgs/suno-backup, which mirrors OUR library to tank/archive/suno).
#
# Volume comes from the discovery lanes, all credential-free:
#   - creator crawl: GET /api/profiles/<handle>/ is public, paginates a
#     creator's whole catalogue, and every seen clip queues its creator;
#   - tag search: POST /api/search/ (search_type=tag_song) is public and
#     returns the winners of any style tag, paginated up to 10k hits per tag;
#     the tag queue is seeded from suno.com's styles sitemap (967 slugs);
#   - playlists: GET /api/playlist/<id>/ is public; playlist ids come from
#     profile responses (whose `playlists` array was previously discarded),
#     the editorial indexes, and playlist owners — each playlist yields clips
#     AND its owner handle, so the creator queue keeps refilling;
#   - editorial indexes (homepage/explore) and contest base clips are queued
#     at most once per `editorialInterval`.
#
# Credential-free against Suno (all endpoints verified unauthenticated; see
# pkgs/suno-top/main.go header); the only secret is the fleet Postgres URL,
# sops-sourced. The URL MUST carry ?sslmode=disable — the fleet Postgres
# serves scram-sha-256 without TLS (modules/services/postgres.nix), and
# lib/pq defaults to sslmode=require.
#
# Suno-side politeness budget (defaults): one discovery POST per interval
# (3m → 480/day) + up to 20 recheck GETs per pass with a 45m per-clip min-age
# + one profile GET per creator per pass (10 → ~4.8k/day) + 2 tag-search POSTs
# and 3 playlist GETs and 5 seed GETs per pass (~3.8k/day combined). Single
# small JSON requests, 300ms apart per lane. The search endpoint rate-limits
# (429) under rapid bursts; set any lane to 0 to disable it.
let
  cfg = config.jupiter.services.sunoTop;

  inherit (import ../lib.nix { inherit config lib pkgs; }) commonServiceHardening;

  pkg = pkgs.callPackage ../../pkgs/suno-top { };
in
{
  options.jupiter.services.sunoTop = {
    enable = lib.mkEnableOption ''
      the public Suno trending-feed harvester: an always-on Go service that
      accumulates the public winners' full clip metadata and play-count growth
      curves into the fleet Postgres (`jupiter` db, `suno` schema)
    '';

    databaseUrlSecret = lib.mkOption {
      type = lib.types.str;
      default = "suno_database_url";
      description = ''
        Name of the sops secret holding the full Postgres connection URL for
        the `suno` role, e.g.
        postgresql://suno:<password>@10.1.1.3:5432/jupiter?sslmode=disable
        (keep the password to [A-Za-z0-9] — the callisto provisioning oneshot
        parses it out of the URL to ALTER ROLE). Add the key to
        secrets/secrets.yaml and the host age recipient to .sops.yaml before
        enabling.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "3m";
      description = ''
        How often one harvest pass runs (systemd time-span string, passed to
        the daemon). Each pass = one trending POST (25 clips max) + up to
        `recheckPassSize` clip re-polls.
      '';
    };

    recheckPassSize = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 20;
      description = ''
        How many stored clips to re-poll per pass for growth-curve data
        (highest play_count first, each at most once per recheckMinAge).
        0 disables rechecks.
      '';
    };

    recheckMinAge = lib.mkOption {
      type = lib.types.str;
      default = "45m";
      description = "Minimum age before a clip is re-polled again.";
    };

    creatorsPerPass = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 10;
      description = ''
        How many creators to walk one profile page each per pass (the volume
        lane: every clip seen queues its creator, and each page yields ~20-30
        more public clips). 0 disables the creator crawl.
      '';
    };

    minUpvotes = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 100;
      description = ''
        Quality floor: only clips with at least this many upvotes are stored
        in any lane (trending, recheck, creator crawl). Rows already stored
        below the floor are pruned at startup. 0 disables the floor.
      '';
    };

    tagsPerPass = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 2;
      description = ''
        How many style tags to walk one search page each per pass (the
        tag-search firehose: POST /api/search/ with search_type=tag_song,
        winners-first by upvote count, 10k hits per tag max). Tag queue is
        seeded from suno.com's styles sitemap. 0 disables the lane.
      '';
    };

    tagPageSize = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 100;
      description = ''
        Clips requested per tag-search page (server caps this at 100).
      '';
    };

    playlistsPerPass = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 3;
      description = ''
        How many public playlists to walk one page each per pass. Playlist
        ids come from profile responses, editorial indexes and playlist
        owners; each page yields full clip objects plus the owner handle.
        0 disables the lane.
      '';
    };

    seedsPerPass = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 5;
      description = ''
        How many one-shot queued clip ids (contest base songs) to fetch per
        pass. 0 disables the lane.
      '';
    };

    editorialInterval = lib.mkOption {
      type = lib.types.str;
      default = "12h";
      description = ''
        Minimum time between refreshes of the editorial playlist indexes
        (homepage/explore) and the contest seed queue (systemd time-span
        string). Persisted in suno.meta, so restarts cannot bypass it.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The fleet Postgres URL (contains the `suno` role password). Read at
    # activation, never in the store.
    sops.secrets.${cfg.databaseUrlSecret} = {
      owner = "root";
      mode = "0400";
    };

    systemd.services.jupiter-suno-top = {
      description = "Public Suno trending harvester → fleet Postgres (suno schema)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        SUNO_TOP_INTERVAL = cfg.interval;
        SUNO_TOP_RECHECKS = toString cfg.recheckPassSize;
        SUNO_TOP_RECHECK_MIN_AGE = cfg.recheckMinAge;
        SUNO_TOP_CREATORS = toString cfg.creatorsPerPass;
        SUNO_TOP_MIN_UPVOTES = toString cfg.minUpvotes;
        SUNO_TOP_TAGS = toString cfg.tagsPerPass;
        SUNO_TOP_TAG_PAGE_SIZE = toString cfg.tagPageSize;
        SUNO_TOP_PLAYLISTS = toString cfg.playlistsPerPass;
        SUNO_TOP_SEEDS = toString cfg.seedsPerPass;
        SUNO_TOP_EDITORIAL_INTERVAL = cfg.editorialInterval;
      };

      serviceConfig = {
        Type = "exec";
        # The DB URL goes in via the process environment, read from the sops
        # file at start (never a unit file, never the store).
        ExecStart = pkgs.writeShellScript "suno-top-start" ''
          export SUNO_TOP_DATABASE_URL="$(cat ${config.sops.secrets.${cfg.databaseUrlSecret}.path})"
          exec ${lib.getExe pkg}
        '';
        Restart = "on-failure";
        RestartSec = "30s";

        # Network (Suno + Postgres) and read access to the sops secret; the
        # daemon is stateless apart from the database.
        ReadOnlyPaths = [ "/run/secrets" ];
      }
      // commonServiceHardening;
    };
  };
}
