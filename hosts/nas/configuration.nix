{ config, pkgs, ... }:

{
  imports = [
    ../../modules/common-stateful.nix
    ../../modules/zfs-nas.nix
    ../../modules/backups.nix
  ];

  networking.hostName = "nas";

  jupiter.backups.paths = [
    "/mnt/nas/important_data"
  ];

  networking.hostId = "deadbeef"; # Must be randomly generated 8-char hex for ZFS

  environment.systemPackages = with pkgs; [
    zfs
    samba
  ];
}
