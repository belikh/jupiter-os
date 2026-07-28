{ config, lib, pkgs, ... }:
let
  cfg = config.jupiter.services.arcadeApi;
  arcadeApi = pkgs.buildGoModule {
    name = "europa-arcade-api";
    src = ../../scripts/europa-arcade-api;
    vendorHash = null;
    meta.mainProgram = "europa-arcade-api";
  };
in
{
  options.jupiter.services.arcadeApi = {
    enable = lib.mkEnableOption "HTTP API server for on-demand arcade ROM downloads";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8765;
      description = "Port for the arcade API server";
    };

    gamesRoot = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/games";
      description = "Root directory where downloaded games are stored";
    };

    cacheDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/cache/pegasus-torrents";
      description = "Directory for transmission torrent cache";
    };
  };

  config = lib.mkIf cfg.enable {
    # Ensure transmission daemon is installed
    environment.systemPackages = [ pkgs.transmission_4 ];

    # Create cache directory
    systemd.tmpfiles.rules = [
      "d ${cfg.cacheDir} 0755 root root - -"
    ];

    # Transmission daemon runs 24/7 to seed Minerva_Myrient back to the community
    services.transmission = {
      enable = true;
      package = pkgs.transmission_4;
      settings = {
        download-dir = cfg.cacheDir;
        incomplete-dir = cfg.cacheDir;
        incomplete-dir-enabled = true;
        rpc-bind-address = "0.0.0.0";
        rpc-port = 9091;
        rpc-enabled = true;
        rpc-whitelist-enabled = false;
      };
    };

    # Systemd service for the arcade API (depends on transmission)
    systemd.services.arcade-api = {
      description = "Jupiter OS Arcade API Server";
      after = [ "network-online.target" "transmission.service" ];
      wants = [ "network-online.target" ];
      requires = [ "transmission.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${arcadeApi}/bin/europa-arcade-api";

        User = "root";
        Group = "root";

        # Restart on failure
        Restart = "on-failure";
        RestartSec = "5s";

        # Standard output to journal
        StandardOutput = "journal";
        StandardError = "journal";
        SyslogIdentifier = "arcade-api";
      };

      environment = {
        GAMES_ROOT = cfg.gamesRoot;
        CACHE_DIR = cfg.cacheDir;
      };
    };
  };
}
