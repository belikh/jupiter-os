{ pkgs, lib, ... }:

# home-manager config for user io — the portable identity shared across every
# personal machine. Keep this conservative and machine-agnostic: anything
# host-specific belongs in the host config, not here.

{
  home.username = "io";
  home.homeDirectory = "/home/io";

  # Match the system stateVersion lineage; bump deliberately, not automatically.
  home.stateVersion = "24.05";

  # User-scoped tools that should follow io everywhere (system-wide CLI baseline
  # lives in modules/common.nix; these are the personal extras).
  home.packages = with pkgs; [
    ripgrep
    fd
    fzf
    bat
    eza
    tealdeer
    btop
    jq
    fuzzel # launcher used by the niri Mod+D bind below
    # chaotic-nyx git builds — track upstream closer than nixpkgs for tools
    # where that matters most (yt-dlp's site-breakage fixes, distrobox).
    distrobox_git
    yt-dlp_git
    # Software KVM to share one keyboard/mouse across io's niri machines.
    # A no-op until a second personal desktop is actually registered in
    # flake.nix (see hosts/desktop, hosts/parents-desktop), but harmless to
    # have ready on every machine io's env roams to.
    lan-mouse_git
  ];

  programs.git = {
    enable = true;
    settings = {
      user.name = "io";
      user.email = "io@jupiter.au";
      init.defaultBranch = "main";
      pull.rebase = true;
    };
  };

  programs.bash = {
    enable = true;
    shellAliases = {
      ls = "eza";
      ll = "eza -l --git";
      cat = "bat -pp";
    };
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # niri config, identical on every personal machine. Written as a plain config
  # file (rather than via a compositor-specific HM module) to avoid coupling to
  # an external module's option schema. The system enables niri itself via
  # jupiter.desktop; this just supplies io's keybindings/layout.
  xdg.configFile."niri/config.kdl".text = ''
    // Jupiter OS — shared niri config for user io.
    // Minimal starting point; grow as needed. Kept identical across machines so
    // muscle memory carries over wherever io logs in.
    input {
        keyboard {
            xkb {
                layout "us"
            }
        }
        focus-follows-mouse
    }

    prefer-no-csd

    binds {
        "Mod+Return" { spawn "kitty"; }
        "Mod+D"      { spawn "fuzzel"; }
        "Mod+Q"      { close-window; }
        "Mod+Shift+E" { quit; }

        "Mod+H" { focus-column-left; }
        "Mod+L" { focus-column-right; }
        "Mod+J" { focus-window-down; }
        "Mod+K" { focus-window-up; }

        "Mod+1" { focus-workspace 1; }
        "Mod+2" { focus-workspace 2; }
        "Mod+3" { focus-workspace 3; }
    }
  '';
}
