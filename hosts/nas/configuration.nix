{ config, pkgs, ... }:

{
  imports = [
    ../../modules/common-stateful.nix
    ./disko.nix # OS SSD layout (destructive, OS disk only)
    ../../modules/storage/zfs-nas.nix # imports tank (new) + europa (archive) + samba
    ../../modules/storage/sanoid.nix # snapshots on tank
    ../../modules/storage/zfs-tuning.nix # ARC/kernel/samba perf for this hardware
    ../../modules/storage/nas-nfs.nix # NFS exports to the network
    ../../modules/storage/iscsi.nix # iSCSI block export of zvols to elitedesk
    ../../modules/storage/replication.nix # pulls server state datasets here (syncoid)
    ../../modules/network/nas-bond.nix # optional 2×1GbE LACP (opt-in below)
    ../../modules/services/backups.nix # restic offsite (jupiter.backups.paths below)
  ];

  networking.hostName = "nas";
  networking.hostId = "deadbeef"; # Stable per-host 8-char hex, required for ZFS

  # RobCo/Fallout boot branding (GRUB theme, MOTD).
  jupiter.branding.enable = true;

  # Static identity below the DHCP pool (.6-.254) so iSCSI/NFS clients have a
  # stable target. DNS (nas.home.jupiter.au) points here. Uses OUR resolver via
  # common.nix default (10.1.1.20). When the LACP bond is enabled, move this
  # address onto bond0.
  networking.useDHCP = false;
  networking.interfaces.enp2s0f0.ipv4.addresses = [
    {
      address = "10.1.1.2";
      prefixLength = 24;
    }
  ];
  networking.defaultGateway = "10.1.1.1";

  # Aggregate the two 1GbE ports once the UniFi switch-side LACP is configured.
  # Leave disabled until then (default DHCP on a single port keeps it reachable).
  jupiter.nas.bond.enable = false;

  # iSCSI block exports for the diskless elitedesk (DB + Loki persistence).
  # Network IQN scheme: iqn.2026-06.au.jupiter:<host>. The initiator IQN below
  # is declared to match the elitedesk's services.openiscsi.name.
  jupiter.nas.iscsi = {
    enable = true;
    luns = [
      {
        name = "db";
        dev = "/dev/zvol/rpool/db";
        initiatorIqn = "iqn.2026-06.au.jupiter:elitedesk";
      }
      {
        name = "loki";
        dev = "/dev/zvol/rpool/loki";
        initiatorIqn = "iqn.2026-06.au.jupiter:elitedesk";
      }
    ];
  };

  # The NAS is the fleet's data hub. It pulls every replicate-enabled host's
  # state here hourly via syncoid — the SOURCES are derived automatically from
  # each host's jupiter.backup in flake.nix (backupHubModule), so no host is
  # enumerated here. Just provide the pull key + enable the puller.
  # See modules/storage/replication.nix for the one-time SSH-key provisioning.
  sops.secrets.syncoid_ssh_key = { }; # add to secrets.yaml before deploying
  jupiter.replication = {
    enable = true;
    sshKeyPath = config.sops.secrets.syncoid_ssh_key.path;
  };

  # Offsite (restic -> cloud): tank/personal plus ALL replicated host state under
  # tank/backups (so any future host the hub pulls is covered without edits
  # here). Media/surveillance/downloads/archive stay on tank's mirror; the frozen
  # europa archive is the user's separate long-term project.
  jupiter.backups.paths = [
    "/tank/personal"
    "/tank/backups"
  ];

  environment.systemPackages = with pkgs; [
    zfs
    samba
    sanoid # provides syncoid too, for manual runs
  ];

  jupiter.services.syncthing.enable = true;
}
