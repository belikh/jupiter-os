{ config, pkgs, ... }:

{
  imports = [
    ../../modules/common-stateful.nix
    ../../modules/home-assistant-vm.nix
    ../../modules/n8n.nix
    ../../modules/services/mqtt.nix
    ../../modules/cloudflared.nix
    ../../modules/headscale.nix
    ../../modules/backups.nix
    ../../modules/pxe-server.nix
    ../../modules/services/dns.nix
  ];

  networking.hostName = "lenovo";
  networking.hostId = "1e110000"; # Stable per-host 8-char hex, required for ZFS

  # RobCo/Fallout boot branding (GRUB theme, MOTD) on this always-on box.
  jupiter.branding.enable = true;

  # Always-on services box: persistent root (no erase-your-darlings rollback) so
  # n8n flows + libvirt images under /var are never wiped. The OS itself is still
  # reproducible from the flake; /var is replicated to the NAS (see backups).
  # ⚠️ disk is a REPLACE-ME placeholder — set the real by-id path before install.
  jupiter.storage = {
    profile = "stateful";
    disk = "/dev/disk/by-id/REPLACE-ME-lenovo-os-disk";
  };

  jupiter.backups.paths = [
    "/var/lib/n8n"
    "/var/lib/libvirt/images"
  ];

  # MQTT broker for Home Assistant + the dashboards' display-mode control.
  # Authenticated: defining `users` turns anonymous access off automatically.
  # The password files hold the plaintext passwords (shared with each client);
  # add the matching entries to secrets/secrets.yaml before deploying.
  sops.secrets.mqtt_homeassistant = { };
  sops.secrets.mqtt_dashboard = { };

  jupiter.services.mqtt = {
    enable = true;
    users = {
      homeassistant.passwordFile = config.sops.secrets.mqtt_homeassistant.path;
      dashboard.passwordFile = config.sops.secrets.mqtt_dashboard.path;
    };
  };

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
