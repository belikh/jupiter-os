{
  config,
  lib,
  pkgs,
  ...
}:

# Headless Skyscraper scraper (europa-side) for the cartridge ROM collections.
#
# Runs Skyscraper against the cartridge platform trees on europa's pool and
# produces Pegasus frontend metadata (metadata.pegasus.txt + media/) that the
# kiosks consume via modules/desktop/cartridges.nix. The generated launch
# lines are of the form `jupiter-retroarch -L <core> "{file.path}"`, where the
# `jupiter-retroarch` wrapper lives kiosk-side and the per-platform core is
# fixed in scripts/cartridge-scrape.sh's system->core map.
#
# Skyscraper's resource cache makes this safe to re-run on a timer: a daily
# pass only fetches games added since the last run, then regenerates the
# Pegasus metadata from cache. Optional ScreenScraper enrichment is wired
# automatically when its sops secret is declared (no credentials required for
# the default thegamesdb source).
#
# See scripts/cartridge-scrape.sh for the per-platform driver. Skyscraper CLI
# reference: https://gemba.github.io/skyscraper/CLIHELP/
let
  cfg = config.jupiter.services.romScraper;

  # Inlined from scripts/ (single source of truth) exactly the way exodos
  # wraps exo-launch.sh, so the store path carries the script's shebang-free
  # runtime shell from writeShellScriptBin.
  scrapeScript = pkgs.writeShellScriptBin "jupiter-cartridge-scrape" (
    builtins.readFile ../../scripts/cartridge-scrape.sh
  );

  # Bucket -> ROM-tree root, so each platform scrapes from the dataset its ROMs
  # were promoted into (mirrors rom-acquire.nix's bucketDir). cartridge-scrape.sh
  # takes a single <romRoot> per invocation, so the service below calls it once
  # per bucket with that bucket's root + its platforms.
  bucketRoot = {
    cartridge = cfg.romRoot;
    optical = cfg.opticalRoot;
    modern = cfg.modernRoot;
  };
  datasetFor = platform: cfg.platformDatasets.${platform} or "cartridge";
  # Distinct buckets among the enabled platforms, in stable order.
  scrapeBuckets = lib.unique (map datasetFor cfg.platforms);
  platformsInBucket = bucket: lib.filter (p: datasetFor p == bucket) cfg.platforms;
in
{
  options.jupiter.services.romScraper = {
    enable = lib.mkEnableOption ''
      headless Skyscraper scraper that builds Pegasus metadata + artwork for
      the cartridge ROM collections on this host
    '';

    romRoot = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/games/cartridge";
      description = ''
        Root of the cartridge-bucket ROM tree. Each cartridge platform lives in
        its own subdirectory (<romRoot>/<platform>/) holding the ROMs; the
        scraper writes metadata.pegasus.txt and a media/ sibling into each. See
        <option>opticalRoot</option> / <option>modernRoot</option> for the other
        two buckets, and <option>platformDatasets</option> for which bucket a
        given platform is scraped from.
      '';
    };

    opticalRoot = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/games/optical";
      description = "Root of the optical-bucket ROM tree (GameCube/Wii).";
    };

    modernRoot = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/games/modern";
      description = "Root of the modern-bucket ROM tree (3DS/Wii U).";
    };

    cacheDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/metadata/skyscraper-cache";
      description = ''
        Skyscraper resource cache root. Each platform gets its own
        <cacheDir>/<platform>/ subfolder (db.xml + resource blobs) so re-runs
        only fetch new/changed games from the scraping source.
      '';
    };

    platforms = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "nes"
        "snes"
        "gb"
        "gbc"
        "gba"
        "n64"
        "fds"
        "virtualboy"
        "pokemonmini"
        "gameandwatch"
        "nds"
        "dsi"
        "gamecube"
        "wii"
        "3ds"
        "new3ds"
        "wiiu"
      ];
      description = ''
        Skyscraper platform names to scrape (one per system subdir under
        <romRoot>). Defaults to every console system the kiosks expose. These
        are passed straight to `Skyscraper -p <platform>`, so each name must be
        a platform Skyscraper recognises; an unrecognised alias is logged and
        skipped by cartridge-scrape.sh (scraping is best-effort — the kiosk
        launch wiring works regardless of whether metadata was generated).
        Verify Skyscraper aliases for the obscure platforms (fds, virtualboy,
        pokemonmini, gameandwatch, dsi, new3ds, wiiu) on first run and adjust
        here if a name differs.
      '';
    };

    source = lib.mkOption {
      type = lib.types.enum [
        "thegamesdb"
        "screenscraper"
        "openretro"
        "arcadedb"
        "igdb"
        "esgamelist"
      ];
      default = "thegamesdb";
      description = ''
        Scraping source for the cache-gathering phase. Defaults to
        `thegamesdb` (no credentials). Use `screenscraper` for the
        ScreenScraper source (credentials via the optional sops secret; see
        SCREENSCRAPER_CREDS below).
      '';
    };

    platformDatasets = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.enum [
          "cartridge"
          "optical"
          "modern"
        ]
      );
      default = {
        nes = "cartridge";
        snes = "cartridge";
        gb = "cartridge";
        gbc = "cartridge";
        gba = "cartridge";
        n64 = "cartridge";
        fds = "cartridge";
        virtualboy = "cartridge";
        pokemonmini = "cartridge";
        gameandwatch = "cartridge";
        nds = "cartridge";
        dsi = "cartridge";
        gamecube = "optical";
        wii = "optical";
        "3ds" = "modern";
        new3ds = "modern";
        wiiu = "modern";
      };
      description = ''
        Which dataset (cartridge/optical/modern) each platform's ROMs live on.
        The scraper resolves each platform's ROM dir as
        `<root of its bucket>/<platform>/`, so optical platforms scrape from
        <option>opticalRoot</option> and modern from <option>modernRoot</option>
        (mirroring the per-bucket verify routing in rom-acquire.nix). Keep in
        sync with rom-acquire.nix's per-system `bucket` and cartridges.nix's
        per-system `dataset`.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      example = "hourly";
      description = ''
        systemd.timer `OnCalendar` expression for the scrape run. Defaults to
        `daily`; `Persistent=true` catches up missed runs after a reboot.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        environment.systemPackages = [ pkgs.skyscraper ];

        # Scraping credentials, decrypted at activation by sops-nix into
        # /run/secrets/... cartridge-scrape.sh consumes the paths via the env
        # vars below: SCREENSCRAPER_CREDS (primary, CRC-exact) and TGDB_APIKEY_FILE
        # (keyed gap-fill). Both are optional at runtime -- the script degrades
        # to unkeyed thegamesdb when a file is empty/absent. The values live in
        # secrets/secrets.yaml. Declared unconditionally here (matching
        # attic-server.nix / cloudflare-tunnel.nix) since every host that
        # enables this module imports sops-nix via common.nix.
        sops.secrets.screenscraper_creds = { };
        sops.secrets.tgdb_apikey = { };

        systemd.services.jupiter-rom-scrape = {
          description = "Scrape console ROMs into Pegasus metadata with Skyscraper";
          serviceConfig.Type = "oneshot";
          # Never run before every dataset holding a scraped platform is mounted.
          unitConfig.RequiresMountsFor = [
            cfg.romRoot
            cfg.opticalRoot
            cfg.modernRoot
          ];
          environment = {
            # Skyscraper is Qt6; without this the headless service cannot
            # construct a platform offscreen surface and aborts.
            QT_QPA_PLATFORM = "offscreen";
            SKYSCRAPER = "${pkgs.skyscraper}/bin/Skyscraper";
            # Activation-time sops secret paths (declarations above); the
            # scripts read these at runtime. ScreenScraper is the primary
            # source, TheGamesDB the keyed onlymissing gap-fill.
            SCREENSCRAPER_CREDS = "${config.sops.secrets.screenscraper_creds.path}";
            TGDB_APIKEY_FILE = "${config.sops.secrets.tgdb_apikey.path}";
          };
          # cartridge-scrape.sh takes a single <romRoot> per invocation, so call
          # it once per bucket with that bucket's root + its platforms. An empty
          # bucket (no platforms) is skipped; a failed bucket doesn't skip the
          # rest (matching cartridge-scrape.sh's own per-platform resilience).
          script = ''
            set -uo pipefail
            rc=0
            ${lib.concatMapStringsSep "\n" (bucket: ''
              echo "jupiter-rom-scrape: bucket '${bucket}' -> ${bucketRoot.${bucket}}"
              ${lib.getExe scrapeScript} \
                '${bucketRoot.${bucket}}' \
                '${cfg.cacheDir}' \
                '${cfg.source}' \
                ${lib.concatStringsSep " " (platformsInBucket bucket)} || rc=1
            '') scrapeBuckets}
            exit "$rc"
          '';
        };

        systemd.timers.jupiter-rom-scrape = {
          description = "Daily Skyscraper cartridge scrape";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = cfg.interval;
            Persistent = true;
          };
        };
      }
    ]
  );
}
