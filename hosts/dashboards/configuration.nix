{ config, pkgs, ... }:

{
  imports = [
    ../../modules/common-stateful.nix
    ./disko.nix # OS disk layout (destructive — confirm device before install)
  ];

  networking.hostName = "jupiter-dashboard";
  networking.hostId = "da58b0a4"; # Stable per-host 8-char hex, required for ZFS

  # Kiosk Mode using Cage (Wayland) + Chromium
  services.xserver.enable = false; # Wayland is lighter and faster for kiosks

  services.cage = {
    enable = true;
    user = "kiosk";
    # Loads the Home Assistant jupiter-ops dashboard directly
    program = "${pkgs.chromium}/bin/chromium --kiosk --incognito --app=https://ha.jupiter.au/jupiter-ops";
  };

  users.users.kiosk = {
    isNormalUser = true;
    extraGroups = [ "video" ];
  };
}
