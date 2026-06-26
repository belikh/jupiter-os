{ config, pkgs, lib, ... }:

with lib;
let
  cfg = config.jupiter.desktop;
in
{
  options.jupiter.desktop = {
    enable = mkEnableOption "Enable desktop environment";
    compositor = mkOption {
      type = types.enum [ "niri" "gnome" "none" ];
      default = "niri";
      description = "Which Wayland compositor to use.";
    };
  };

  config = mkIf cfg.enable {
    # If Niri is chosen
    programs.niri.enable = cfg.compositor == "niri";

    # If GNOME is chosen
    services.xserver.enable = cfg.compositor == "gnome";
    services.displayManager.gdm.enable = cfg.compositor == "gnome";
    services.desktopManager.gnome.enable = cfg.compositor == "gnome";

    # Common Desktop Packages for Niri (Noctalia-inspired)
    environment.systemPackages = mkIf (cfg.compositor == "niri") (with pkgs; [
      waybar
      fuzzel
      mako
      swaybg
      kitty
      wl-clipboard
      xdg-utils
    ]);

    # Fonts
    fonts.packages = with pkgs; [
      inter
      jetbrains-mono
    ];
  };
}
