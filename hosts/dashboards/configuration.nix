{ config, pkgs, ... }:

{
  networking.hostName = "jupiter-dashboard";
  system.stateVersion = "24.05";

  # Kiosk Mode using Cage (Wayland) + Chromium
  services.xserver.enable = false; # Wayland is lighter and faster for kiosks
  
  programs.cage = {
    enable = true;
    user = "kiosk";
    # Loads the Home Assistant jupiter-ops dashboard directly
    program = "${pkgs.chromium}/bin/chromium --kiosk --incognito --app=http://10.1.1.72:8123/jupiter-ops";
  };
  
  users.users.kiosk = {
    isNormalUser = true;
    extraGroups = [ "video" ];
  };

  # Touchscreen support out of the box in Wayland/Cage
}
