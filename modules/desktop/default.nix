{
  config,
  pkgs,
  lib,
  ...
}:

with lib;
let
  cfg = config.jupiter.desktop;
in
{
  options.jupiter.desktop = {
    enable = mkEnableOption "Enable desktop environment";
    compositor = mkOption {
      type = types.enum [
        "niri"
        "gnome"
        "none"
      ];
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

    # Base Desktop Profile - Installed on ALL Jupiter OS desktops
    environment.systemPackages =
      with pkgs;
      [
        # Core CLI & Dev
        git
        htop
        ripgrep
        fd
        jq
        fzf
        bat
        eza
        wget
        curl
        unzip

        # AI Coding Prereqs
        nodejs # Required to install @anthropic-ai/claude-code & @google/antigravity globally

        # GUI Essentials
        google-chrome
        vscode
        pavucontrol
        mpv
      ]
      ++ (
        if (cfg.compositor == "niri") then
          [
            # Dank Linux / DankMaterialShell (Niri-specific)
            # Replaces waybar/fuzzel/mako with AGS and Material You tools
            ags
            dart-sass
            awww
            matugen
            kitty
            wl-clipboard
            xdg-utils
            brightnessctl
          ]
        else
          [ ]
      );

    # Fonts
    fonts.packages = with pkgs; [
      inter
      jetbrains-mono
      material-symbols
      (pkgs.callPackage ../../packages/share-tech-mono/default.nix { })
    ];
  };
}
