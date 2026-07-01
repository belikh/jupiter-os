{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.jupiter.desktop;
in
{
  options.jupiter.desktop = {
    enable = lib.mkEnableOption "Enable desktop environment";
    compositor = lib.mkOption {
      type = lib.types.enum [
        "niri"
        "gnome"
        "none"
      ];
      default = "niri";
      description = "Which Wayland compositor to use.";
    };
  };

  config = lib.mkIf cfg.enable {
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
        # Core CLI tooling (git, ripgrep, jq, …) is in modules/common.nix, so it
        # lands on headless hosts too. Only desktop-specific extras live here.

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
