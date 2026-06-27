{ config, pkgs, ... }:

{
  imports = [
    ../../modules/common-stateful.nix
    ./disko.nix # OS SSD layout (destructive, OS disk only)
    ../../modules/zfs-nas.nix # imports tank (new) + europa (archive) + samba
    ../../modules/storage/sanoid.nix # snapshots on tank
    ../../modules/storage/zfs-tuning.nix # ARC/kernel/samba perf for this hardware
    ../../modules/storage/nas-nfs.nix # NFS exports to the network
    ../../modules/network/nas-bond.nix # optional 2×1GbE LACP (opt-in below)
    ../../modules/backups.nix # restic offsite (jupiter.backups.paths below)
  ];

  networking.hostName = "nas";
  networking.hostId = "deadbeef"; # Stable per-host 8-char hex, required for ZFS

  # Aggregate the two 1GbE ports once the UniFi switch-side LACP is configured.
  # Leave disabled until then (default DHCP on a single port keeps it reachable).
  jupiter.nas.bond.enable = false;

  # Offsite (restic -> cloud): only the irreplaceable, reasonably-sized data on
  # the NEW pool. Media/surveillance/downloads/archive stay on tank's mirror.
  # The frozen europa archive is the user's separate long-term project.
  jupiter.backups.paths = [
    "/tank/personal"
    "/tank/backups/homeassistant"
  ];

  environment.systemPackages = with pkgs; [
    zfs
    samba
    sanoid # provides syncoid too, for manual runs
  ];
}
