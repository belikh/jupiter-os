{ config, lib, ... }:

# Opt-in declarative user environment for the primary admin account (io),
# managed by home-manager. Personal machines (laptop, desktops) set
# jupiter.home.enable = true to get an identical login — same dotfiles, user
# packages, and niri config — wherever io sits down. Data directories
# (Documents, Projects, …) are NOT managed here; they roam via Syncthing
# (jupiter.services.syncthing) with the NAS as hub.

let
  cfg = config.jupiter.home;
in
{
  options.jupiter.home = {
    enable = lib.mkEnableOption "declarative home-manager environment for user io";
  };

  config = lib.mkIf cfg.enable {
    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;
      users.io = import ./io.nix;
    };
  };
}
