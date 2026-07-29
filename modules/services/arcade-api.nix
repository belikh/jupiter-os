{ config, lib, pkgs, ... }:
let
  cfg = config.jupiter.services.arcadeApi;
in
{
  options.jupiter.services.arcadeApi = {
    enable = lib.mkEnableOption "HTTP API server for on-demand arcade ROM downloads via aria2c + Minerva torrents";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8765;
      description = "Port for the arcade API server";
    };

    cacheDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/cache/pegasus-roms";
      description = "Directory for downloaded ROM cache";
    };
  };

  config = lib.mkIf cfg.enable {
    # aria2 is required to extract files from .torrent files
    environment.systemPackages = [ pkgs.aria2 ];

    # Create cache directory for downloaded ROMs
    systemd.tmpfiles.rules = [
      "d ${cfg.cacheDir} 0755 root root - -"
    ];
  };
}
