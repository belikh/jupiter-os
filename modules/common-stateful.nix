{ lib, ... }:

{
  imports = [ ./common.nix ];

  # Bootloader setup
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Fallback root filesystem (mkDefault) so a host without its own disko layout
  # still evaluates. Every real host imports a disko.nix that overrides this at
  # normal priority (see hosts/<host>/disko.nix).
  fileSystems."/" = {
    device = lib.mkDefault "/dev/disk/by-label/nixos";
    fsType = lib.mkDefault "ext4";
  };
}
