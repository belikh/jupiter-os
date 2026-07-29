{
  config,
  lib,
  ...
}:

let
  cfg = config.jupiter.services.arcadeApi;
in
{
  options.jupiter.services.arcadeApi = {
    enable = lib.mkEnableOption "arcade-api HTTP server for on-demand ROM downloads via Minerva torrents";
  };

  config = lib.mkIf cfg.enable {
    # aria2 is required for arcade-api to extract files from .torrent files
    environment.systemPackages = with config.pkgs; [
      aria2
    ];
  };
}
