{ config, pkgs, ... }:

{
  imports = [
    ../../modules/home-assistant-vm.nix
    ../../modules/n8n.nix
    ../../modules/cloudflared.nix
    ../../modules/headscale.nix
  ];

  networking.hostName = "lenovo";
  system.stateVersion = "24.05";

  # Ensure the machine uses the local Headscale DNS or 1.1.1.1
  networking.nameservers = [ "1.1.1.1" ];

  # Dummy root filesystem to allow NixOS evaluation to pass
  fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
}
