{ config, pkgs, ... }:

{
  imports = [
    ../../modules/common-stateful.nix
  ];

  networking.hostName = "t460s";
  networking.hostId = "c0ffee00"; # Randomly generated 8-char hex for ZFS

  # Dendritic Feature Toggles
  jupiter = {
    branding.enable = true; # RobCo/Fallout boot branding (GRUB theme, MOTD)
    core.impermanence.enable = true;
    home.enable = true; # declarative io env (dotfiles, niri config) — roams
    desktop = {
      enable = true;
      compositor = "niri";
    };
    storage = {
      profile = "impermanent"; # erase-your-darlings root; /persist survives
      disk = "/dev/nvme0n1";
    };
    services.syncthing.enable = true;
  };
}
