{
  config,
  lib,
  pkgs,
  ...
}:

# Public Suno trending-feed harvester (fleet Postgres consumer).
#
# Always-on Go service (pkgs/suno-top, built via pkgs.callPackage) that polls
# Suno's PUBLIC trending feed and accumulates every unique clip into the fleet
# Postgres (db `jupiter`, schema `suno`, DDL applied by the daemon on first
# connect — same pattern as the procurement stack). Each clip is stored with
# its complete object (prompts/tags/counts) plus an append-only sighting log
# capturing play_count over time AND the clip's rank in the trending rotation.
# Purpose: a queryable dataset of the public winners for hit-model research
# and prompt-style distributions (cf. pkgs/suno-backup, which mirrors OUR
# library to tank/archive/suno).
#
# Credential-free against Suno (all endpoints verified unauthenticated,
# 2026-09-04 — see pkgs/suno-top/main.go header); the only secret is the
# fleet Postgres URL, sops-sourced. The URL MUST carry ?sslmode=disable —
# the fleet Postgres serves scram-sha-256 without TLS (modules/services/
# postgres.nix), and lib/pq defaults to sslmode=require.
#
# Suno-side politeness budget (defaults): one discovery POST per interval
# (3m → 480/day) + up to 20 recheck GETs per pass with a 45m per-clip
# min-age. Single small JSON requests; SUNO_TOP_RECHECKS=0 disables rechecks.
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
        postgresql://suno:<password>@127.0.0.1:5432/jupiter?sslmode=disable
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
