{
  config,
  lib,
  pkgs,
  ...
}:

# arcade-webapp — the jupiterOS Arcade pipeline webapp (gauntlet plan
# docs/plans/arcade-webapp-gauntlet.md Phase 1, ADR-0002): one NixOS-native
# app on europa owning the whole cartridge-ROM pipeline. Phase 1 ships the
# pipeline dashboard: a scanner that imports the console-system catalogue
# (the store copy of scripts/cartridge-catalogue.tsv below — the Go side
# parses the TSV itself, same semantics as arcade-catalogue.nix), walks the
# three games buckets, reads No-Intro DAT currency dates, counts Skyscraper
# cache coverage, imports the legacy arcade-inventory JSON (transition aid)
# and summarizes the aria2 incoming tree into SQLite (on-pool state file
# per ADR-0002 D3), plus an htmx-polling dashboard with an on-demand
# rescan. P2 adds the download-control surface: an aria2 JSON-RPC client
# (secret read at runtime from the sops path, never inlined, never
# logged), the downloads page (2s-polled queue + the system-centric join
# against verify state + per-system torrent acquire into
# incomingDir/<sys>). Verify/scrape control land in Phases 3+.
#
# LAN-only by design (like suno-web): no reverse-proxy exposure, no tunnel
# wiring — flip <option>openFirewall</option> for trusted-LAN access.
#
# Secrets discipline (house rule): the *File options below take PATHS.
# sops-nix decrypts the values at activation; the app reads files at
# runtime and never sees inline values, and nothing secret ever enters the
# nix store. P2 consumes the aria2 secret; P5 (ScreenScraper/TGDB)
# consumes the rest.
let
  cfg = config.jupiter.services.arcadeWebapp;

  inherit (import ../lib.nix { inherit config lib pkgs; }) commonServiceHardening;

  pkg = pkgs.callPackage ../../pkgs/arcade-webapp { };

  # The committed TSV, copied into the store so the Go scanner parses the
  # same rows every consumer derives from (rom-scraper.nix pattern).
  catalogueTsv = pkgs.writeText "cartridge-catalogue.tsv" (
    builtins.readFile ../../scripts/cartridge-catalogue.tsv
  );

  # Pool paths the unit must not start before (rom-acquire.nix pattern).
  poolPaths = [
    cfg.cartridgeRoot
    cfg.opticalRoot
    cfg.modernRoot
    cfg.datDir
    cfg.skyscraperCacheDir
    cfg.incomingDir
    cfg.stateDir
  ];
in
{
  options.jupiter.services.arcadeWebapp = {
    enable = lib.mkEnableOption ''
      the jupiterOS Arcade pipeline webapp: scanner + htmx dashboard over
      the retro trees (per-system ROM counts/sizes, DAT currency, verify
      state, Skyscraper cache coverage, scan status, recent runs)
    '';

    package = lib.mkOption {
      type = lib.types.package;
      default = pkg;
      description = ''
        The arcade-webapp package to run. Defaults to the in-tree source at
        pkgs/arcade-webapp (ADR-0002 D2) built with this host's pkgs.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8094;
      description = "TCP port the webapp listens on (suno-web holds 8093, nom-web 8092).";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open <option>port</option> in the firewall. The dashboard is a
        LAN-first operator surface (like suno-web): leave the tunnel out of
        it.
      '';
    };

    catalogueTsv = lib.mkOption {
      type = lib.types.path;
      default = catalogueTsv;
      description = ''
        The console-system catalogue TSV the scanner imports (system facts
        single source). Defaults to a store copy of
        scripts/cartridge-catalogue.tsv.
      '';
    };

    cartridgeRoot = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/games/cartridge";
      description = ''
        Cartridge-bucket games root. Each catalogue system lives at
        <literal>&lt;root&gt;/&lt;system&gt;/</literal>; missing systems read
        as empty. Mirrors <option>jupiter.services.romAcquire.cartridgeDir</option>.
      '';
    };

    opticalRoot = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/games/optical";
      description = "Optical-bucket games root (GameCube/Wii/PS1/... disc images).";
    };

    modernRoot = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/games/modern";
      description = "Modern-bucket games root (3DS/Wii U images).";
    };

    datDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/metadata/no-intro-dats";
      description = ''
        No-Intro DAT directory, one <literal>&lt;system&gt;.dat</literal>
        per catalogue system. The scanner reads each DAT's Logiqx header
        (name/version/date) for the DAT-currency card; a missing DAT renders
        as "no dat". Mirrors
        <option>jupiter.services.romAcquire.datDir</option>.
      '';
    };

    skyscraperCacheDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/metadata/skyscraper-cache";
      description = ''
        Skyscraper resource cache root (rom-scraper.nix's cacheDir). The
        scanner counts distinct game ids in each platform's
        <literal>&lt;dir&gt;/&lt;skyPlatform&gt;/db.xml</literal> for the
        coverage card — a presence-level heuristic; the per-type coverage
        tracker lands with Phase 3 (P5).
      '';
    };

    incomingDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/cache/incoming/nointro-nintendo";
      description = ''
        The aria2 download root the acquire oneshot stages torrents into
        (rom-acquire.nix's incomingDir). Phase 1 summarizes files+bytes for
        the status strip; P2 attributes queue entries to systems by this
        root (<literal>&lt;dir&gt;/&lt;sys&gt;/</literal>) and routes
        acquire submissions into it.
      '';
    };

    torrentDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/metadata/minerva-torrents";
      description = ''
        Directory holding the Minerva/Myrient No-Intro .torrent files
        (rom-acquire.nix's torrentDir), one per system named by the
        catalogue's torrent column. The downloads page's per-system
        acquire action submits <literal>&lt;dir&gt;/&lt;torrent&gt;
        </literal> to the aria2 daemon when present; read-only access is
        enough (the daemon, not the webapp, writes the download).
      '';
    };

    aria2RpcUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:6800/jsonrpc";
      description = ''
        URL of the fleet aria2 daemon's JSON-RPC endpoint
        (<option>jupiter.services.aria2</option>; europa-local default).
        Download control (P2) is enabled when this and
        <option>aria2SecretFile</option> are both set.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/state";
      description = ''
        Runtime state directory (ADR-0001 boundary: on-pool runtime state,
        not config). The SQLite database lives at
        <literal>&lt;dir&gt;/arcade-webapp.db</literal> (WAL mode; ADR-0002
        D3). Must be writable by the service.
      '';
    };

    inventoryFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      # Literal default matching arcade-inventory.nix's stateFile (the
      # cross-module reference would throw on hosts that don't import that
      # module — suno-web.nix's dataDir note explains the pattern). null
      # disables the import.
      default = "/tank/archive/retro/state/inventory.json";
      description = ''
        The legacy jupiter-arcade-inventory JSON, imported on every scan as
        a transition aid (P8 subsumes the inventory). Absent or null is
        tolerated — the dashboard renders from the scanner's own data.
      '';
    };

    aria2SecretFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "config.sops.secrets.jupiter_aria2_rpc_secret.path";
      description = ''
        File PATH holding the aria2 JSON-RPC secret. Set this to
        <literal>config.sops.secrets.jupiter_aria2_rpc_secret.path</literal>
        — the SAME existing sops secret the aria2 daemon and the acquire
        oneshot read (declared by
        <option>jupiter.services.aria2</option>/<option>jupiter.services.romAcquire</option>
        when enabled on the host); never the value itself, never a new
        secret. The webapp reads the file at RUNTIME, once per RPC call,
        and sends it as the JSON-RPC <literal>token:</literal> parameter
        per the aria2 spec — the value never enters the nix store, the
        unit environment, or any log (grep-proven by unit tests).

        No new privileges are needed for this: the service already runs
        as root with <literal>ProtectSystem=strict</literal>, and sops
        secrets are root-readable at their default 0400 (the
        <literal>io:users</literal> ownership aria2.nix sets on europa
        is also root-readable). The webapp does NOT write the download
        tree — the aria2 daemon does — so <option>incomingDir</option>
        stays read-only to it.
      '';
    };

    screenscraperCredsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "config.sops.secrets.screenscraper_creds.path";
      description = ''
        File PATH holding the ScreenScraper credentials (sops secret path,
        not value). Consumed by the metadata-engine piece (P5); Phase 1
        only checks presence.
      '';
    };

    tgdbApikeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "config.sops.secrets.tgdb_apikey.path";
      description = ''
        File PATH holding the TheGamesDB API key (sops secret path, not
        value). Consumed by the metadata-engine piece (P5); Phase 1 only
        checks presence.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The state dir must exist BEFORE the service starts: with
    # ProtectSystem=strict, systemd builds the unit's mount namespace
    # (ReadWritePaths) prior to ExecStartPre, and a missing path fails the
    # whole unit at step NAMESPACE (226) — an ExecStartPre mkdir can never
    # run in time. tmpfiles is the blessed declarative creator (runs at
    # boot, and activation-time on switch).
    systemd.tmpfiles.rules = [ "d '${cfg.stateDir}' 0750 root root -" ];

    systemd.services.jupiter-arcade-webapp = {
      description = "jupiterOS Arcade pipeline webapp (scanner + dashboard)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        # tmpfiles must have created the state dir before this unit's
        # mount namespace is built (see the tmpfiles rule below).
        "systemd-tmpfiles-setup.service"
      ];
      wants = [ "systemd-tmpfiles-setup.service" ];

      # Don't start until every pool path is mounted (rom-acquire.nix /
      # suno-web.nix pattern) — the scanner walks them at startup.
      unitConfig.RequiresMountsFor = poolPaths;

      environment = {
        ARCADE_WEBAPP_ADDR = ":${toString cfg.port}";
        ARCADE_WEBAPP_CATALOGUE_TSV = toString cfg.catalogueTsv;
        ARCADE_WEBAPP_CARTRIDGE_ROOT = cfg.cartridgeRoot;
        ARCADE_WEBAPP_OPTICAL_ROOT = cfg.opticalRoot;
        ARCADE_WEBAPP_MODERN_ROOT = cfg.modernRoot;
        ARCADE_WEBAPP_DAT_DIR = cfg.datDir;
        ARCADE_WEBAPP_SKYSCRAPER_CACHE_DIR = cfg.skyscraperCacheDir;
        ARCADE_WEBAPP_INCOMING_DIR = cfg.incomingDir;
        ARCADE_WEBAPP_TORRENT_DIR = cfg.torrentDir;
        ARCADE_WEBAPP_ARIA2_RPC_URL = cfg.aria2RpcUrl;
        ARCADE_WEBAPP_DB = "${cfg.stateDir}/arcade-webapp.db";
      }
      # Optional inputs append via optionalAttrs (absent options never
      # reference undeclared sops paths — the arcade-inventory.nix
      # publishMqtt pattern). Secret PATHS only: the app reads files at
      # runtime; values never enter the store or the journal.
      // lib.optionalAttrs (cfg.inventoryFile != null) {
        ARCADE_WEBAPP_INVENTORY_FILE = cfg.inventoryFile;
      }
      // lib.optionalAttrs (cfg.aria2SecretFile != null) {
        ARCADE_WEBAPP_ARIA2_SECRET_FILE = toString cfg.aria2SecretFile;
      }
      // lib.optionalAttrs (cfg.screenscraperCredsFile != null) {
        ARCADE_WEBAPP_SCREENSCRAPER_CREDS_FILE = toString cfg.screenscraperCredsFile;
      }
      // lib.optionalAttrs (cfg.tgdbApikeyFile != null) {
        ARCADE_WEBAPP_TGDB_APIKEY_FILE = toString cfg.tgdbApikeyFile;
      };

      preStart = ''
        # Belt-and-braces after tmpfiles: covers a state dir on a pool
        # dataset whose mount just appeared (RequiresMountsFor orders this
        # unit after it; tmpfiles ran before the mount existed).
        mkdir -p '${cfg.stateDir}'
      '';

      serviceConfig = {
        Type = "exec";
        ExecStart = "${lib.getExe cfg.package}";
        Restart = "on-failure";
        RestartSec = "10s";

        # Deliberately NOT DynamicUser (suno-web can afford it because its
        # state lives in a StateDirectory; this service writes its SQLite
        # state ON-POOL per ADR-0002 D3, and a dynamic uid can't own
        # /tank/archive/retro/state). Root like suno-backup, with the same
        # strict sandbox: write ONLY the state dir, read-only everything
        # else. Common stanza shared with nom-web/suno-web/suno-backup
        # (modules/lib.nix: commonServiceHardening).
        ReadWritePaths = [ cfg.stateDir ];
        ReadOnlyPaths = [
          cfg.cartridgeRoot
          cfg.opticalRoot
          cfg.modernRoot
          cfg.datDir
          cfg.skyscraperCacheDir
          cfg.incomingDir
        ];
      }
      // commonServiceHardening;
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
