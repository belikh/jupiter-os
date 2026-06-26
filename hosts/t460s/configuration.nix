{ config, pkgs, ... }:

{
  imports = [
    ../../modules/common-stateful.nix
  ];

  networking.hostName = "t460s";

  # Setup standard desktop environment
  services.xserver.enable = true;
  services.xserver.desktopManager.gnome.enable = true;
  services.xserver.displayManager.gdm.enable = true;
}
