{
  config,
  lib,
  pkgs,
  ...
}:

# Suno account library backup daemon (europa-side).
#
# An always-on Go service (pkgs/suno-backup, built via pkgs.callPackage) that
# mirrors a Suno account's track library — lossless WAV masters plus the
# COMPLETE per-clip metadata object (lyrics, prompts, tags, project, counts,
# flags, media_urls, …) — into tank/archive/suno. Suno ships no official API,
# so the daemon replays the browser session against the same internal endpoints
# the suno.com web app uses:
#
#   - the long-lived Clerk __client cookie (refresh JWT, ~1yr) -> 1-hour access
#     JWTs via auth.suno.com (keep-alive),
#   - GET /api/feed/v2?page=N lists the library (20 clips/page, newest first),
#   - POST /api/gen/<id>/convert_wav/ + GET /api/gen/<id>/wav_file/ generates
#     and yields the lossless master (WAV is on-demand, not a static file).
#
# Reads are not captcha-gated, so no browser/captcha-solving sidecar is needed.
# The __client cookie value is held in the sops secret `suno_cookie` (read at
# activation, never in the Nix store) — refresh it by re-extracting from a
# logged-in browser when the daemon logs an auth failure (~annually).
#
# Two concurrent loops: a recent scan (catches freshly generated tracks every
# `interval`) and a continuous resumable backfill that walks the page cursor
# through history. Both are idempotent (index keyed by clip id) and persist
# progress after every successful backup, so restarts resume without re-work —
# a 23k+ track library is a multi-day one-time backfill that progresses safely.
let
  cfg = config.jupiter.services.sunoBackup;

  # Built from in-tree source alongside this module. Stdlib-only, so it
  # substitutes clean on europa's btver2-tuned closure (Go ignores gccarch) and
  # needs no new flake input. Exposed standalone as `.#suno-backup` in flake.nix
  # for vendorHash recompute / local iteration.
  pkg = pkgs.callPackage ../../pkgs/suno-backup { };
in
{
  options.jupiter.services.sunoBackup = {
    enable = lib.mkEnableOption ''
      the Suno account library backup daemon: an always-on Go service that
      mirrors a Suno account's WAV masters + complete per-clip metadata into a
      dataset on europa, authenticating via the Clerk __client cookie in the
      `suno_cookie` sops secret
    '';

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/suno";
      description = ''
        Destination root for the backup. Must be a mounted path (the service
        unit gates on RequiresMountsFor this). Defaults to the
        `tank/archive/suno` ZFS dataset (modules/storage/zfs-nas.nix). Layout
        under it: index.json (clip id -> {wav sha256/bytes, cover sha256/bytes,
        backfill cursor} state), and tracks/<YYYY>/<MM>/<id>/{<id>.wav,
        cover.jpg, meta.json} — the lossless master, the large cover art, and
        the complete clip object (lyrics/prompts/tags/…).
      '';
    };

    cookieSecret = lib.mkOption {
      type = lib.types.str;
      default = "suno_cookie";
      description = ''
        Name of the sops secret holding the Clerk `__client` cookie value (the
        refresh JWT, ~1yr). The daemon reads the bare token from the secret
        file at activation. Add the corresponding key to secrets/secrets.yaml
        and the europa age recipient to .sops.yaml before enabling.
      '';
    };

    recentPages = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = ''
        Number of newest feed pages (20 clips each) the recent scan walks every
        `interval`. Covers the freshly-generated window so new tracks are caught
        within one cycle; the deep history is owned by the backfill loop.
      '';
    };

    backfillStep = lib.mkOption {
      type = lib.types.ints.positive;
      default = 25;
      description = ''
        Feed pages walked per backfill pass. Bounds work between recent scans so
        a huge library backfills gradually without hogging bandwidth. Each pass
        resumes from the persisted cursor in index.json.
      '';
    };

    concurrency = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = ''
        Maximum in-flight clip backups (WAV convert+poll+download). WAV
        conversion is server-side at Suno, so keep this modest to avoid looking
        like abuse — 3 is a polite default that still yields a steady ~one
        track per ~10s.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "30m";
      description = ''
        How often the recent scan runs (systemd time-span string, passed
        verbatim to the daemon). Short enough to catch new tracks promptly,
        long enough not to busy-loop while backfill chews through history.
      '';
    };

    pollInterval = lib.mkOption {
      type = lib.types.str;
      default = "5s";
      description = "Delay between wav_file polls while a WAV is being generated.";
    };

    convertTimeout = lib.mkOption {
      type = lib.types.str;
      default = "3m";
      description = ''
        Max wait for a single track's WAV conversion. The web app caps this at
        120s; the daemon allows a little more slack before giving up (the clip
        is retried on the next pass).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The __client refresh token — a long-lived session credential. Read at
    # activation (never in the store). Mirrors modules/core/crush.nix's
    # sops.secrets pattern. Owner root, mode 0400 (the service runs as root so
    # it can write the dataset).
    sops.secrets.${cfg.cookieSecret} = {
      owner = "root";
      mode = "0400";
    };

    systemd.services.jupiter-suno-backup = {
      description = "Suno account library backup (WAV masters + full metadata)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "sops-nix.service"
      ];
      wants = [ "network-online.target" ];

      # Don't start until the dataset is mounted (mirrors rom-acquire.nix).
      unitConfig.RequiresMountsFor = [ cfg.dataDir ];

      environment = {
        SUNO_COOKIE_PATH = config.sops.secrets.${cfg.cookieSecret}.path;
        SUNO_DATA_DIR = cfg.dataDir;
        SUNO_RECENT_PAGES = toString cfg.recentPages;
        SUNO_BACKFILL_STEP = toString cfg.backfillStep;
        SUNO_CONCURRENCY = toString cfg.concurrency;
        SUNO_INTERVAL = cfg.interval;
        SUNO_POLL_INTERVAL = cfg.pollInterval;
        SUNO_CONVERT_TIMEOUT = cfg.convertTimeout;
      };

      serviceConfig = {
        Type = "exec";
        ExecStart = "${lib.getExe pkg}";
        Restart = "on-failure";
        RestartSec = "30s";

        # Hardening: the daemon needs the network (Suno + Clerk + the CDN),
        # read access to the sops secret under /run/secrets, and write access
        # only to the dataset. Everything else is locked down.
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir ];
        ReadOnlyPaths = [ "/run/secrets" ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = false; # Go runtime needs writable+executable memory
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
      };
    };
  };
}
