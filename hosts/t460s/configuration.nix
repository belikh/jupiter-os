{ config, pkgs, ... }:

{
  imports = [
    ../../modules/common-stateful.nix
  ];

  networking.hostName = "t460s";
  networking.hostId = "deadbeef"; # Randomly generated 8-char hex for ZFS

  # Dendritic Feature Toggles
  jupiter = {
    core.impermanence.enable = true;
    desktop = {
      enable = true;
      compositor = "niri";
    };
    storage.zfs = {
      enable = true;
      disk = "/dev/nvme0n1";
    };
  };
}
