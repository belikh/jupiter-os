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
# incomingDir/<sys>). P3 adds verify & organize + DAT currency: an igir
# runner exec'ing the retired cartridge-verify.sh's flag set (scripts/
# deprecated/; + the aria2-metadata
# input exclusion, D-P3e: COPY promotion, .aria2 in-flight skip, per-bucket routing, promote-unchecked when the
# DAT is missing), a Fresh1G1R McLean DAT manager (on demand + on a
# schedule), report ingestion into SQLite, and the zero-unmatched
# indicator — plus torrent staging (upload a .torrent / paste a
# magnet-URL) closing the P2 critic's acquire dead-end. P5 adds the
# metadata-engine control surface: a Skyscraper driver exec'ing
# the retired cartridge-scrape.sh's three-pass flow (ScreenScraper primary /
# configured-source onlymissing gap-fill / Pegasus compose, offscreen,
# credential FILES read at call time), a serialized scrape queue with
# per-system + per-game actions on the /metadata page, run history with
# coverage deltas, and an in-process schedule carrying the old
# jupiter-rom-scrape daily timer's cadence. P6 adds the launcher-DB
# generator: the SQLite store becomes the source of truth and the app
# renders each populated system dir's metadata.pegasus.txt into the
# served trees (catalogue launch lines, relative paths, hidden-game
# exclusion, pending split for incomplete downloads) — temp+fsync+rename
# only, strict-parser validated before any swap, byte-stable for
# unchanged state, serialized through the shared pipeline lock. P7 adds
# curation: per-game hide/show toggles, bulk unhide, and custom
# cross-system collections whose CRUD edits trigger an asynchronous
# regeneration through the same lock — no new write surfaces beyond the
# trees and state dir already listed below.
#
# LAN-only by design (like suno-web): no reverse-proxy exposure, no tunnel
# wiring — flip <option>openFirewall</option> for trusted-LAN access.
#
# Secrets discipline (house rule): the *File options below take PATHS.
# sops-nix decrypts the values at activation; the app reads files at
# runtime and never sees inline values, and nothing secret ever enters the
# nix store. P2 consumes the aria2 secret; P5 consumes ScreenScraper/TGDB
# (the Skyscraper driver reads both credential FILES per scrape call).
let
  cfg = config.jupiter.services.arcadeWebapp;

  inherit (import ../lib.nix { inherit config lib pkgs; }) commonServiceHardening;

  pkg = pkgs.callPackage ../../pkgs/arcade-webapp { };

  # The committed TSV, copied into the store so the Go scanner parses the
  # same rows every consumer derives from (the retired rom-scraper.nix
  # pioneered the pattern; see scripts/deprecated/ for its era).
  catalogueTsv = pkgs.writeText "cartridge-catalogue.tsv" (
    builtins.readFile ../../scripts/cartridge-catalogue.tsv
  );

  # Pool paths the unit must not start before (the retired
  # rom-acquire.nix established the pattern).
  # torrentDir is covered transitively on europa today (it sits under the
  # same dataset as datDir/skyscraperCacheDir) but the ordering INTENT is
  # per-path: the downloads page stats it at render time, so it belongs
  # here explicitly (ADV-P2-05). scratchDir (P3: igir audit reports) joins
  # the same gate.
  poolPaths = [
    cfg.cartridgeRoot
    cfg.opticalRoot
    cfg.modernRoot
    cfg.datDir
    cfg.skyscraperCacheDir
    cfg.incomingDir
    cfg.torrentDir
    cfg.scratchDir
    cfg.stateDir
  ]
  ++ lib.optionals (cfg.exoRoot != null) [ cfg.exoRoot ];
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
        as empty. Same path the retired rom-acquire module called
        <literal>cartridgeDir</literal>.
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
        the retired rom-acquire module's <literal>datDir</literal>.
      '';
    };

    skyscraperCacheDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/metadata/skyscraper-cache";
      description = ''
        Skyscraper resource cache root (the retired rom-scraper.nix called
        this cacheDir). The
        scanner counts distinct game ids in each platform's
        <literal>&lt;dir&gt;/&lt;skyPlatform&gt;/db.xml</literal> for the
        coverage card; the P5 scrape driver WRITES the same cache (gather
        passes + Pegasus compose, one per-system config ini at the root),
        so it is on the unit's ReadWritePaths.
      '';
    };

    artDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Optional cover-media root for the P4 gallery/detail surfaces
        (Skyscraper's media layout): covers live at
        <literal>&lt;root&gt;/&lt;systemKey&gt;/&lt;rom basename without
        extension&gt;/cover.png</literal> (or .jpg). When set, the
        <literal>/art/&lt;system&gt;/&lt;game&gt;</literal> route serves a
        present cover file; a missing cover falls back to a deterministic
        generated SVG poster. Read-only to the service.
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
        </literal> to the aria2 daemon when present; P3's stage-torrent
        upload writes operator-supplied .torrent files here under the
        catalogue-expected name, so the webapp needs WRITE access (the
        downloads themselves are still written by the daemon, not the
        webapp).
      '';
    };

    scratchDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/scratch";
      description = ''
        Scratch working area (rom-acquire.nix's scratchDir): igir audit
        CSV reports land under <literal>&lt;dir&gt;/reports/</literal>
        (one <literal>&lt;system&gt;.csv</literal> per verify, served on
        the verify page).
      '';
    };

    igirPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.igir;
      description = ''
        The igir package the verify runner execs (gauntlet P3). Defaults
        to <literal>pkgs.igir</literal> — igir 5.3.0 is IN the fleet's
        pinned nixpkgs (the same binary <command>make
        fixture-arcade</command> pins via <command>nix run
        --inputs-from . nixpkgs#igir</command>), so no store-path
        workaround is needed. Verify runs
        <literal>igir copy test report</literal> with
        scripts/deprecated/cartridge-verify.sh's flag set plus an
        input-anchored <literal>--input-exclude
        &lt;input&gt;/**/*.torrent</literal> (aria2's infohash metadata
        companions in the download tree — see the runner's D-P3e note).
      '';
    };

    skyscraperPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.skyscraper;
      description = ''
        The Skyscraper package the metadata driver execs (gauntlet P5).
        Defaults to <literal>pkgs.skyscraper</literal> — 3.18.5 is IN the
        fleet's pinned nixpkgs (verified the same way as igir, D-P3a), so
        no store-path workaround is needed and no new flake input is
        added (AC-9). Scrape runs the retired cartridge-scrape.sh's
        three-pass flow
        per system (ScreenScraper primary via
        <option>screenscraperCredsFile</option>, configured-source
        onlymissing gap-fill via <option>tgdbApikeyFile</option>, Pegasus
        compose) with <literal>QT_QPA_PLATFORM=offscreen</literal>, into
        <option>skyscraperCacheDir</option>.
      '';
    };

    scrapeIntervalHours = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = 24;
      description = ''
        Hours between scheduled full scrapes (every system whose games
        tree holds ROM files; one at a time — a tick landing while a
        manual scrape runs is skipped, never stacked). null disables the
        schedule — the on-demand buttons on the metadata page always
        work. The default (24) matches the retired jupiter-rom-scrape
        daily timer's cadence; there is deliberately NO startup scrape
        (community APIs have real quota costs).
      '';
    };

    datFetchBaseUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://raw.githubusercontent.com/UnluckyForSome/Fresh1G1R/main/daily-1g1r-dat/McLean";
      description = ''
        Base URL of the Fresh1G1R McLean 1G1R DAT tree the DAT manager
        fetches per-system DATs from (scripts/deprecated/fetch-mclean-
        1g1r-dats.sh's URL
        family). Overridable so the VM test stubs the host — tests never
        touch GitHub.
      '';
    };

    datRefreshIntervalHours = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = 168;
      description = ''
        Hours between scheduled McLean DAT refreshes (plus one at
        startup). null disables the schedule — the on-demand refresh
        buttons on the verify page always work. Failures are per-system
        warnings recorded as dat-fetch runs, never fatal. The default
        (168 = weekly) matches the DATs' own refresh cadence.
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

    exoRoot = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      # Literal default matching arcade-inventory.nix's exoRoot. null
      # disables the eXo import entirely.
      default = "/tank/archive/retro/games/curated";
      description = ''
        Root of the eXo curated collections (P8): each is read READ-ONLY
        at <literal>&lt;root&gt;/exo-&lt;name&gt;/metadata.pegasus.txt</literal>
        (dos, win3x, win9x — generated kiosk-side by
        jupiter-exodos-metadata.service via scripts/exo-to-pegasus.py) and
        imported into the store as source=exo systems, giving browse,
        curation and coverage surfaces over them. Generation for these
        systems deliberately STAYS kiosk-side — the webapp never writes
        into this root (read-only to the service). Absent files are
        normal on hosts without the curated mounts.
      '';
    };

    aria2SecretFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "config.sops.secrets.jupiter_aria2_rpc_secret.path";
      description = ''
        File PATH holding the aria2 JSON-RPC secret. Set this to
        <literal>config.sops.secrets.jupiter_aria2_rpc_secret.path</literal>
        — the SAME existing sops secret the aria2 daemon reads at startup
        (declared by <option>jupiter.services.aria2</option> when enabled
        on the host; per D-P2b this option is a pure pointer — the webapp
        module declares no sops secrets of its own); never the value
        itself, never a new secret. The webapp reads the file at RUNTIME,
        once per RPC call,
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
        not value). Consumed by the metadata driver (P5): read at scrape
        call time and passed to Skyscraper's <literal>-u</literal> — the
        value never enters a log, an error, or the store. Unset, the
        ScreenScraper primary pass is skipped and the configured source
        scrapes alone.
      '';
    };

    tgdbApikeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "config.sops.secrets.tgdb_apikey.path";
      description = ''
        File PATH holding the TheGamesDB API key (sops secret path, not
        value). Consumed by the metadata driver (P5) for its default
        gap-fill source, read at scrape call time like
        <option>screenscraperCredsFile</option>.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The state dir must exist BEFORE the service starts: with
    # ProtectSystem=strict, systemd builds the unit's mount namespace
    # (ReadWritePaths) prior to ExecStartPre, and a missing path fails the
    # whole unit at step NAMESPACE (226) — an ExecStartPre mkdir can never
    # run in time. tmpfiles is the blessed declarative creator (runs at
    # boot, and activation-time on switch). scratchDir joins the same
    # treatment (P3: the igir report writer needs it).
    systemd.tmpfiles.rules = [
      "d '${cfg.stateDir}' 0750 root root -"
      "d '${cfg.scratchDir}/reports' 0750 root root -"
    ];

    systemd.services.jupiter-arcade-webapp = {
      description = "jupiterOS Arcade pipeline webapp (scanner + dashboard)";
      wantedBy = [ "multi-user.target" ];
      path = [
        pkgs.p7zip
        pkgs.which
      ];
      after = [
        "network.target"
        # tmpfiles must have created the state dir before this unit's
        # mount namespace is built (see the tmpfiles rule below).
        "systemd-tmpfiles-setup.service"
      ];
      wants = [ "systemd-tmpfiles-setup.service" ];

      # Don't start until every pool path is mounted (rom-acquire.nix /
      # suno-web.nix pattern) — the scanner walks them at startup. The
      # optional art root joins the gate only when configured.
      unitConfig.RequiresMountsFor = poolPaths ++ lib.optionals (cfg.artDir != null) [ cfg.artDir ];

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
        ARCADE_WEBAPP_IGIR_BIN = lib.getExe cfg.igirPackage;
        # P5: the metadata driver (Skyscraper) — always wired when the
        # module is enabled, like igir. The interval maps null → "0"
        # explicitly (the app's own default when the env is ABSENT is 24,
        # so a bare omission could not express "disabled").
        ARCADE_WEBAPP_SKYSCRAPER_BIN = lib.getExe cfg.skyscraperPackage;
        ARCADE_WEBAPP_SCRAPE_INTERVAL_HOURS =
          if cfg.scrapeIntervalHours == null then "0" else toString cfg.scrapeIntervalHours;
        ARCADE_WEBAPP_DAT_FETCH_BASE_URL = cfg.datFetchBaseUrl;
        ARCADE_WEBAPP_SCRATCH_DIR = cfg.scratchDir;
        ARCADE_WEBAPP_DB = "${cfg.stateDir}/arcade-webapp.db";
      }
      # Optional inputs append via optionalAttrs (absent options never
      # reference undeclared sops paths — the arcade-inventory.nix
      # publishMqtt pattern). Secret PATHS only: the app reads files at
      # runtime; values never enter the store or the journal.
      // lib.optionalAttrs (cfg.inventoryFile != null) {
        ARCADE_WEBAPP_INVENTORY_FILE = cfg.inventoryFile;
      }
      # P8 eXo import: read-only curated-collection root.
      // lib.optionalAttrs (cfg.exoRoot != null) {
        ARCADE_WEBAPP_EXO_ROOT = cfg.exoRoot;
      }
      // lib.optionalAttrs (cfg.aria2SecretFile != null) {
        ARCADE_WEBAPP_ARIA2_SECRET_FILE = toString cfg.aria2SecretFile;
      }
      // lib.optionalAttrs (cfg.screenscraperCredsFile != null) {
        ARCADE_WEBAPP_SCREENSCRAPER_CREDS_FILE = toString cfg.screenscraperCredsFile;
      }
      // lib.optionalAttrs (cfg.tgdbApikeyFile != null) {
        ARCADE_WEBAPP_TGDB_APIKEY_FILE = toString cfg.tgdbApikeyFile;
      }
      // lib.optionalAttrs (cfg.datRefreshIntervalHours != null) {
        ARCADE_WEBAPP_DAT_REFRESH_HOURS = toString cfg.datRefreshIntervalHours;
      }
      # P4 gallery covers: only wired when configured — unwired, the app
      # serves SVG posters only (its own log line says so).
      // lib.optionalAttrs (cfg.artDir != null) {
        ARCADE_WEBAPP_ART_DIR = cfg.artDir;
      };

      preStart = ''
        # Belt-and-braces after tmpfiles: covers a state dir on a pool
        # dataset whose mount just appeared (RequiresMountsFor orders this
        # unit after it; tmpfiles ran before the mount existed). The
        # scratch report dir shares the same rationale (P3).
        mkdir -p '${cfg.stateDir}' '${cfg.scratchDir}/reports'
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
        # strict sandbox. Write surface as of P5 (the webapp owns verify +
        # organize + DAT currency + torrent staging + Skyscraper
        # scraping, per the plan):
        #   - stateDir            the SQLite database
        #   - scratchDir          igir audit reports
        #   - datDir              fetched McLean DATs (temp+rename)
        #   - torrentDir          stage-torrent uploads (catalogue-named)
        #   - skyscraperCacheDir  the resource cache the P5 driver writes
        #     (gather passes, per-system config ini) and the scanner reads
        #   - the three bucket roots — igir COPY-promotes verified ROMs
        #     into them (the pipeline's whole point; on europa they are
        #     on-pool datasets, writable by design); the P5 Pegasus
        #     compose additionally drops metadata/media next to ROMs (-g);
        #     the P6 launcher-DB generator writes each populated system
        #     dir's metadata.pegasus.txt (+ temp siblings only, atomic
        #     rename) into the same trees
        # Everything else stays read-only: the incoming staging tree is
        # the daemon's to write. Common stanza shared with
        # nom-web/suno-web/suno-backup (modules/lib.nix:
        # commonServiceHardening).
        ReadWritePaths = [
          cfg.stateDir
          cfg.scratchDir
          cfg.datDir
          cfg.torrentDir
          cfg.skyscraperCacheDir
          cfg.cartridgeRoot
          cfg.opticalRoot
          cfg.modernRoot
        ];
        ReadOnlyPaths = [
          cfg.incomingDir
        ]
        ++ lib.optionals (cfg.artDir != null) [ cfg.artDir ]
        # The curated trees are the kiosk-side generator's to write; the
        # webapp only parses their metadata files (P8).
        ++ lib.optionals (cfg.exoRoot != null) [ cfg.exoRoot ];
      }
      // commonServiceHardening;
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
