{ ... }:

{
  imports = [ ./common.nix ];

  # Bootloader setup
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Dummy root filesystem to allow NixOS evaluation to pass until ZFS layout is implemented
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
}
