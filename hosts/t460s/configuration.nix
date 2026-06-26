{ config, pkgs, ... }:

{
  networking.hostName = "t460s";
  system.stateVersion = "24.05";

  # Setup standard desktop environment
  services.xserver.enable = true;
  services.xserver.desktopManager.gnome.enable = true;
  services.xserver.displayManager.gdm.enable = true;

  # Base user profile
  users.users.io = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
  };

  fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
}
