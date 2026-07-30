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
        Root of the cartridge ROM tree. Each platform lives in its own
        subdirectory (<romRoot>/<platform>/) holding the ROMs; the scraper
        writes metadata.pegasus.txt and a media/ sibling into each.
      '';
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
      ];
      description = ''
        Skyscraper platform names to scrape. Defaults to the six cartridge
        systems the kiosks expose.
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

        systemd.services.jupiter-rom-scrape = {
          description = "Scrape cartridge ROMs into Pegasus metadata with Skyscraper";
          serviceConfig.Type = "oneshot";
          # Never run before the pool/dataset holding the ROM tree is mounted.
          unitConfig.RequiresMountsFor = [ cfg.romRoot ];
          environment = {
            # Skyscraper is Qt6; without this the headless service cannot
            # construct a platform offscreen surface and aborts.
            QT_QPA_PLATFORM = "offscreen";
            SKYSCRAPER = "${pkgs.skyscraper}/bin/Skyscraper";
          };
          script = ''
            exec ${lib.getExe scrapeScript} \
              '${cfg.romRoot}' \
              '${cfg.cacheDir}' \
              '${cfg.source}' \
              ${lib.concatStringsSep " " cfg.platforms}
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

      # Optional ScreenScraper enrichment: wired automatically when (and only
      # when) a `screenscraper_creds` sops secret is declared on this host.
      # The three-part guard stays eval-safe even if sops-nix isn't imported.
      # The secret path is read at activation (sops-nix decrypts to
      # /run/secrets/...); the script reads it at runtime to pass `-u`.
      (lib.mkIf (config ? sops && config.sops ? secrets && config.sops.secrets ? screenscraper_creds) {
        systemd.services.jupiter-rom-scrape.environment.SCREENSCRAPER_CREDS =
          "${config.sops.secrets.screenscraper_creds.path}";
      })
    ]
  );
}
