{ config, pkgs, ... }:

{
  imports = [
    ../../modules/common-stateful.nix
  ];

  networking.hostName = "himalia";
  networking.hostId = "c0ffee00"; # Randomly generated 8-char hex for ZFS

  # Confirmed Intel i5-6200U (Skylake-U, same family as the kiosks' i5-6300U)
  # via `lscpu` — safe to target for the "rebuild the world" build-server
  # workflow (see docs/roadmap.md).
  jupiter.build.microarch = "skylake";

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
    services.haAgent.enable = true; # Home Assistant companion daemon (belikh/ha-linux-agent)
    # Interactive desktop/laptop — scx_bpfland is tuned for foreground-app
    # responsiveness, a better fit than the gaming-tuned fleet default.
    core.scheduler = {
      enable = true;
      name = "scx_bpfland";
    };
  };
}
