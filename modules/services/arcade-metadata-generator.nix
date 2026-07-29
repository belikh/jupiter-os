{
  config,
  lib,
  pkgs,
  ...
}:

# jupiterOS Arcade Metadata Generator — runs on europa (NAS) to generate
# Pegasus collection files from curated collections + 1G1R DATs.
# Output served via NFS to kiosks at /tank/archive/retro/metadata/pegasus/
# Also runs a scraper to enrich 1G1R collections with metadata + assets via Hasheous.

let
  cfg = config.jupiter.arcade.metadataGenerator;
in
{
  options.jupiter.arcade.metadataGenerator = {
    enable = lib.mkEnableOption "jupiterOS Arcade metadata generator (runs on europa)";

    # NFS archive root (local path on europa)
    nfsRoot = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive";
      description = "Local path to retro archive root";
    };

    # Output directory for Pegasus collections
    outputDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/metadata/pegasus/collections";
      description = "Where to write generated collection .txt files";
    };

    # Assets directory for boxart/screenshots/logos
    assetsDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/metadata/pegasus/assets";
      description = "Where to symlink assets";
    };

    # Separate output directory for curated collections only (used by kiosks)
    curatedOutputDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/metadata/pegasus/collections/curated";
      description = "Where to write curated-only collection .txt files (for kiosk Pegasus)";
    };

    # Python script paths
    scriptPath = lib.mkOption {
      type = lib.types.path;
      default = ./scripts/generate-arcade-metadata.py;
      description = "Path to the metadata generator script";
    };

    # 1G1R metadata scraper script path
    scraperScriptPath = lib.mkOption {
      type = lib.types.path;
      default = ./scripts/scrape-1g1r-metadata.py;
      description = "Path to the 1G1R metadata scraper script";
    };

    # Timer schedule
    timerSchedule = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "systemd timer schedule (e.g., 'daily', 'weekly', '*-*-* 04:00:00')";
    };

    # Scraper timer schedule (separate, runs after generator)
    scraperTimerSchedule = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 06:00:00";
      description = "systemd timer schedule for 1G1R scraper (runs after generator)";
    };

    # Collections to generate (default: all - curated + 1G1R = ~57k games)
    collections = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "all" ];
      description = "Collections to generate: 'curated', '1g1r', 'all', or specific names";
    };
  };

  config = lib.mkIf cfg.enable {
    # Ensure output directories exist
    systemd.tmpfiles.rules = [
      "d ${cfg.outputDir} 0755 root root -"
      "d ${cfg.assetsDir} 0755 root root -"
      "d ${cfg.assetsDir}/boxart 0755 root root -"
      "d ${cfg.assetsDir}/screenshots 0755 root root -"
      "d ${cfg.assetsDir}/logos 0755 root root -"
      "d ${cfg.curatedOutputDir} 0755 root root -"
    ];

    # Generator service (oneshot)
    systemd.services.arcade-metadata-generate = {
      description = "Generate Pegasus metadata from curated collections + 1G1R DATs";
      path = [ pkgs.python3 pkgs.unzip pkgs.p7zip pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        # Read-only access to source collections, write to output
        ReadWritePaths = [ cfg.outputDir cfg.assetsDir cfg.curatedOutputDir ];
        ReadOnlyPaths = [ cfg.nfsRoot ];
      };
      script = ''
        set -eu
        echo "[$(date)] Starting arcade metadata generation..."
        ${pkgs.python3.interpreter} ${cfg.scriptPath} \
          --nfs-root ${cfg.nfsRoot} \
          --output ${cfg.outputDir} \
          --assets ${cfg.assetsDir} \
          --collections ${toString cfg.collections} \
          --curated-output ${cfg.curatedOutputDir}
        echo "[$(date)] Metadata generation complete."
      '';
    };

    # 1G1R metadata scraper service (oneshot) - enriches 1G1R collections with Hasheous metadata
    systemd.services.arcade-metadata-scrape-1g1r = {
      description = "Enrich 1G1R Pegasus collections with Hasheous metadata + assets";
      path = [ pkgs.python3 pkgs.python3Packages.requests ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        ReadWritePaths = [ cfg.outputDir cfg.assetsDir ];
        ReadOnlyPaths = [ cfg.nfsRoot ];
        # Need network access for Hasheous API
        PrivateNetwork = false;
      };
      script = ''
        set -eu
        echo "[$(date)] Starting 1G1R metadata scrape..."
        ${pkgs.python3.interpreter} ${cfg.scraperScriptPath} \
          --collections-dir ${cfg.outputDir} \
          --assets-dir ${cfg.assetsDir} \
          --collections ${toString cfg.collections} \
          --rate-limit 0.1
        echo "[$(date)] 1G1R metadata scrape complete."
      '';
    };

    # Timer to run generation periodically
    systemd.timers.arcade-metadata-generate = {
      description = "Daily Pegasus metadata regeneration";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.timerSchedule;
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };

    # Timer to run scraper after generator (daily at 6 AM by default)
    systemd.timers.arcade-metadata-scrape-1g1r = {
      description = "Daily 1G1R metadata enrichment via Hasheous";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.scraperTimerSchedule;
        Persistent = true;
        RandomizedDelaySec = "30m";
      };
    };
  };
}