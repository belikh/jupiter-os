{ config, pkgs, ... }:

{
  imports = [
    ../../modules/common-stateful.nix
    ./disko.nix # OS disk layout (destructive — confirm device before install)
    ../../modules/home-assistant-vm.nix
    ../../modules/n8n.nix
    ../../modules/cloudflared.nix
    ../../modules/headscale.nix
    ../../modules/backups.nix
    ../../modules/pxe-server.nix
    ../../modules/services/dns.nix
  ];

  networking.hostName = "lenovo";
  networking.hostId = "1e110000"; # Stable per-host 8-char hex, required for ZFS

  jupiter.backups.paths = [
    "/var/lib/n8n"
    "/var/lib/libvirt/images"
  ];

  # ---- Network-wide DNS resolver (this host) -------------------------------
  jupiter.dns = {
    enable = true;
    domain = "home.jupiter.au"; # site 1 internal split-horizon zone
    allowedNetworks = [
      "127.0.0.0/8"
      "::1/128"
      "10.1.1.0/24" # Default LAN
      "192.168.2.0/24" # IOT VLAN
      "192.168.3.0/24" # Cameras VLAN
      "100.64.0.0/10" # headscale mesh
    ];
    records = {
      "gateway.home.jupiter.au" = "10.1.1.1";
      "nas.home.jupiter.au" = "10.1.1.2";
      "lenovo.home.jupiter.au" = "10.1.1.20";
      "ha.home.jupiter.au" = "10.1.1.72";
      "smokeping.home.jupiter.au" = "10.1.1.221";
    };
  };

  # The resolver host points at itself (overrides common's 10.1.1.20 default).
  networking.nameservers = [ "127.0.0.1" ];

  # Static LAN identity on the HA bridge: 10.1.1.20 (existing reservation).
  networking.useDHCP = false;
  networking.bridges.br0.interfaces = [ "enp1s0" ]; # Declarative bridge configured per-host
  networking.interfaces.br0.ipv4.addresses = [
    {
      address = "10.1.1.20";
      prefixLength = 24;
    }
  ];
  networking.defaultGateway = "10.1.1.1";
}
