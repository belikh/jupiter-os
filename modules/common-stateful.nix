{ lib, ... }:

{
  imports = [ ./common.nix ];

  # Bootloader setup
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Dummy root filesystem to allow NixOS evaluation to pass until ZFS layout is implemented
  fileSystems."/" = {
    device = lib.mkDefault "/dev/disk/by-label/nixos";
    fsType = lib.mkDefault "ext4";
  };
}
