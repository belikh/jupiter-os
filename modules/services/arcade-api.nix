{ config, lib, pkgs, ... }:
let
  cfg = config.jupiter.services.arcadeApi;
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
    let
      arcadeApi = pkgs.buildGoModule {
        name = "europa-arcade-api";
        src = ../../scripts/europa-arcade-api;
        vendorHash = null;
        meta.mainProgram = "europa-arcade-api";
      };
    in
    {
      # Ensure transmission daemon is installed and available
      environment.systemPackages = [ pkgs.transmission_4 ];

      # Create cache directory
      systemd.tmpfiles.rules = [
        "d ${cfg.cacheDir} 0755 root root - -"
      ];

      # Systemd service for the arcade API
      systemd.services.arcade-api = {
        description = "Jupiter OS Arcade API Server";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
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
  };
}
