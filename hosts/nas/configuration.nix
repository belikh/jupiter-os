{ config, pkgs, ... }:

{
  imports = [
    ../../modules/zfs-nas.nix
  ];

  networking.hostName = "jupiter-nas";
  networking.hostId = "deadbeef"; # Must be randomly generated 8-char hex for ZFS
  system.stateVersion = "24.05";

  environment.systemPackages = with pkgs; [
    zfs
    samba
  ];

  fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
}
