{
  config,
  lib,
  pkgs,
  ...
}:

# jupiterOS Arcade Metadata Generator — runs on europa (NAS) to generate
# Pegasus collection files from curated collections + 1G1R DATs.
# Output served via NFS to kiosks at /tank/archive/retro/metadata/pegasus/

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

    # Python script path
    scriptPath = lib.mkOption {
      type = lib.types.path;
      default = ../../scripts/generate-arcade-metadata.py;
      description = "Path to the metadata generator script";
    };

    # Timer schedule
    timerSchedule = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "systemd timer schedule (e.g., 'daily', 'weekly', '*-*-* 04:00:00')";
    };

    # Collections to generate (default: all)
    collections = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "all" ];
      description = "Collections to generate (subset of known collections)";
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
    ];

    # Generator service (oneshot)
    systemd.services.arcade-metadata-generate = {
      description = "Generate Pegasus metadata from curated collections + 1G1R DATs";
      path = [
        pkgs.python3
        pkgs.unzip
        pkgs.p7zip
        pkgs.coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        # Read-only access to source collections, write to output
        ReadWritePaths = [
          cfg.outputDir
          cfg.assetsDir
        ];
        ReadOnlyPaths = [ cfg.nfsRoot ];
      };
      script = ''
        set -eu
        echo "[$(date)] Starting arcade metadata generation..."
        ${pkgs.python3.interpreter} ${cfg.scriptPath} \
          --nfs-root ${cfg.nfsRoot} \
          --output ${cfg.outputDir} \
          --assets ${cfg.assetsDir} \
          --collections ${toString cfg.collections}
        echo "[$(date)] Metadata generation complete."
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
  };
}
