{ config, pkgs, ... }:

{
  imports = [
    ../../modules/common-stateful.nix
    ../../modules/home-assistant-vm.nix
    ../../modules/n8n.nix
    ../../modules/cloudflared.nix
    ../../modules/headscale.nix
    ../../modules/backups.nix
    ../../modules/pxe-server.nix
  ];

  networking.hostName = "lenovo";

  # Ensure the machine uses the local Headscale DNS or 1.1.1.1
  networking.nameservers = [ "1.1.1.1" ];

  # Configure the network bridge for Home Assistant
  networking.useDHCP = false;
  networking.bridges.br0.interfaces = [ "enp1s0" ]; # Declarative bridge configured per-host
  networking.interfaces.br0.useDHCP = true;
}
