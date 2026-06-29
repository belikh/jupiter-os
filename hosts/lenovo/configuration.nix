{ config, pkgs, lib, ... }:

let
  # Shared network facts (VLANs/subnets/records/resolver) — see lib/site.nix.
  site = import ../../lib/site.nix;
in
{
  imports = [
    ../../modules/common-stateful.nix
    ../../modules/services/home-assistant-vm.nix
    ../../modules/services/n8n.nix
    ../../modules/services/mqtt.nix
    ../../modules/network/cloudflared.nix
    ../../modules/network/headscale.nix
    ../../modules/network/pxe-server.nix
    ../../modules/network/dns.nix
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

  # No direct offsite backup here: /var (the dataset holding n8n flows + libvirt
  # images) is pulled to the NAS hourly via syncoid, and the NAS is the single
  # offsite egress (see jupiter.replication on nas). Authorize the NAS's syncoid
  # key to pull as root.
  # ⚠️ REPLACE-ME: paste the NAS syncoid public key (generated at provisioning,
  # see modules/storage/replication.nix). The placeholder authorizes nothing.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 REPLACE-ME-nas-syncoid-pubkey nas-syncoid"
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
  # Domain, allow-list, and records all come from lib/site.nix so they stay in
  # lock-step with the UniFi VLAN/subnet config in terraform/unifi.
  jupiter.dns = {
    enable = true;
    domain = site.domain;
    allowedNetworks = [
      "127.0.0.0/8"
      "::1/128"
    ]
    ++ (lib.mapAttrsToList (_: net: net.networkCidr) site.networks)
    ++ site.meshCidrs;
    records = site.records;
  };

  # The resolver host points at itself (overrides common's resolver default).
  networking.nameservers = [ "127.0.0.1" ];

  # Static LAN identity on the HA bridge (existing reservation).
  networking.useDHCP = false;
  networking.bridges.br0.interfaces = [ "enp1s0" ]; # Declarative bridge configured per-host
  networking.interfaces.br0.ipv4.addresses = [
    {
      address = site.resolver;
      prefixLength = 24;
    }
  ];
  networking.defaultGateway = site.gateway;
}
