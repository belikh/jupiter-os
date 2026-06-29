{
  config,
  pkgs,
  lib,
  modulesPath,
  ...
}:

let
  # Shared network facts — elitedesk has a static identity so the Wyze cams can
  # forward syslog to a stable elitedesk.home.jupiter.au.
  site = import ../../lib/site.nix;
in
{
  imports = [
    (modulesPath + "/installer/netboot/netboot-minimal.nix")
    ../../modules/common.nix
    ../../modules/services/postgresql.nix
    ../../modules/services/loki.nix
  ];

  networking.hostName = "elitedesk";

  # Branding (GRUB) is opt-in and left off here: it would conflict with the
  # netboot profile's bootloader-less setup, and it's purely cosmetic on a
  # headless node anyway.

  # Ensure the image is fully copied to RAM on boot
  boot.kernelParams = [ "copytoram" ];

  # Diskless compute node: persists DB + Loki to the NAS over iSCSI.
  # Auto-discovers and logs into the NAS target at boot, attaching the LUNs as
  # local block devices.
  services.openiscsi = {
    enable = true;
    name = "iqn.2026-06.au.jupiter:elitedesk"; # matches the NAS ACL
    enableAutoLoginOut = true;
    discoverPortal = "nas.home.jupiter.au:3260";
  };

  # Mount the iSCSI LUNs where the services expect their state. First-time only:
  # label each LUN once it's attached, e.g.
  #   mkfs.ext4 -L db   /dev/disk/by-path/...-lun-0
  #   mkfs.ext4 -L loki /dev/disk/by-path/...-lun-1
  # `nofail` + `_netdev` keep boot from hanging if the NAS is briefly absent.
  fileSystems."/var/lib/postgresql" = {
    device = "/dev/disk/by-label/db";
    fsType = "ext4";
    options = [
      "_netdev"
      "nofail"
    ];
  };
  fileSystems."/var/lib/loki" = {
    device = "/dev/disk/by-label/loki";
    fsType = "ext4";
    options = [
      "_netdev"
      "nofail"
    ];
  };

  # The database (on the db LUN) and Loki + syslog receiver (on the loki LUN).
  # Postgres serves two consumers that currently run on lenovo over the LAN:
  #   - homeassistant: the HA VM's recorder. HA is a HAOS VM (not NixOS), so we
  #     only provision the db/role here; set `recorder: db_url:` inside HA to
  #     postgresql://homeassistant:<pw>@elitedesk.home.jupiter.au/homeassistant
  #   - n8n: lenovo's n8n, migrated off SQLite (see hosts/lenovo).
  # Add pg_homeassistant_password and pg_n8n_password to secrets.yaml first.
  sops.secrets.pg_homeassistant_password.owner = "postgres";
  sops.secrets.pg_n8n_password.owner = "postgres";

  jupiter.services.postgresql = {
    enable = true;
    databases = {
      homeassistant = {
        passwordFile = config.sops.secrets.pg_homeassistant_password.path;
        allowedClients = [ "${site.records."ha.home.jupiter.au"}/32" ]; # the HA VM
      };
      n8n = {
        passwordFile = config.sops.secrets.pg_n8n_password.path;
        allowedClients = [ "${site.resolver}/32" ]; # lenovo (where n8n runs)
      };
    };
  };

  jupiter.services.loki.enable = true; # also ingests Wyze cam syslog on :514

  # Static identity so the cams' syslog target (elitedesk.home.jupiter.au) and
  # iSCSI clients resolve to a stable address.
  networking.useDHCP = false;
  networking.interfaces.enp0s31f6.ipv4.addresses = [
    {
      address = site.records."elitedesk.home.jupiter.au";
      prefixLength = 24;
    }
  ];
  networking.defaultGateway = site.gateway;
  networking.nameservers = [ site.resolver ];

  # Static hosts entry so the boot-time iSCSI attach doesn't race the resolver
  # coming up (the NAS target must resolve before openiscsi logs in).
  networking.hosts."10.1.1.2" = [ "nas.home.jupiter.au" ];
}
