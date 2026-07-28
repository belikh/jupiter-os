{
  config,
  lib,
  pkgs,
  ...
}:

# jupiterOS Arcade — Pegasus frontend with on-demand ROM loading via NFS + mirrors.
#
# Architecture (per issue #30):
# - Curated collections (eXoDOS, eXoWin3x, C64 Dreams, OneLoad64, etc.) live on
#   europa NAS at /tank/archive/retro/games/curated/, served read-only via NFS.
# - 1G1R collections (No-Intro, Redump) store only DAT metadata on NFS at
#   /tank/archive/retro/games/1g1r/; ROMs are fetched from Myrient mirrors on
#   first play.
# - Pegasus metadata collections + assets served from NFS at
#   /tank/archive/retro/metadata/pegasus/
# - Launcher script (pegasus-rom-launch) dispatches:
#     * cache hit → instant launch
#     * curated ZIP on NFS → extract to /tmp/pegasus-cache (ephemeral) via TUI
#     * 1G1R game → download from Myrient to /var/cache/pegasus-roms (persistent) via TUI
# - Bubble Tea TUI (bubbletea-game-loader) shows progress with cancel support.
# - Two-tier cache: /tmp/pegasus-cache (cleared on reboot) + /var/cache/pegasus-roms (persisted via impermanence).
# - Kiosks are consumers only — no timers, no API server, no DAT processing.

let
  cfg = config.jupiter.arcade;

  # Build the Bubble Tea game loader from Go source
  bubbleteaGameLoader = pkgs.stdenv.mkDerivation {
    name = "bubbletea-game-loader";
    src = ./scripts/bubbletea-game-loader;
    nativeBuildInputs = [ pkgs.go ];
    buildPhase = ''
      export GOPATH=$PWD/.gopath
      mkdir -p $GOPATH/src
      ln -sf $PWD $GOPATH/src/bubbletea-game-loader
      cd $GOPATH/src/bubbletea-game-loader
      go build -o bubbletea-game-loader .
    '';
    installPhase = ''
      mkdir -p $out/bin
      cp $GOPATH/src/bubbletea-game-loader/bubbletea-game-loader $out/bin/
    '';
  };

  # Custom Pegasus theme: "jupiterOS arcade". Touch-friendly, Catppuccin Mocha palette.
  # Files live in the Nix store and are symlinked into the gamer user's themes dir via tmpfiles.
  jupiterArcadeTheme = pkgs.stdenv.mkDerivation {
    name = "jupiteros-arcade-theme";
    src = ./jupiteros-arcade-theme;
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r ./. $out/
      runHook postInstall
    '';
  };
in
{
  options.jupiter.arcade = {
    enable = lib.mkEnableOption "jupiterOS Arcade (Pegasus + on-demand ROM loading)";

    # NFS mount configuration
    nfsHost = lib.mkOption {
      type = lib.types.str;
      default = "10.1.1.2"; # europa's static LAN IP
      description = "NFS host serving /tank/archive/retro";
    };

    nfsPath = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro";
      description = "Path on NFS host to the retro archive root";
    };

    mountPoint = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive";
      description = "Where to mount the NFS export on this kiosk";
    };

    # Cache directories
    tmpCacheDir = lib.mkOption {
      type = lib.types.str;
      default = "/tmp/pegasus-cache";
      description = "Ephemeral extraction cache (cleared on reboot)";
    };

    persistentCacheDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/cache/pegasus-roms";
      description = "Persistent download cache (survives reboot via impermanence)";
    };

    # Pegasus metadata location on NFS
    pegasusCollectionsDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/metadata/pegasus/collections";
      description = "NFS path to Pegasus collection files";
    };

    pegasusAssetsDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/metadata/pegasus/assets";
      description = "NFS path to Pegasus assets (boxart, screenshots, logos)";
    };

    # User that runs the Pegasus session
    sessionUser = lib.mkOption {
      type = lib.types.str;
      default = "gamer";
      description = "User that owns the Pegasus config and runs the arcade session";
    };

    # Launcher script path (installed to /usr/local/bin)
    launcherScript = lib.mkOption {
      type = lib.types.path;
      default = ./scripts/pegasus-rom-launch;
      description = "Path to the pegasus-rom-launch wrapper script";
    };

    # Theme for Pegasus
    theme = lib.mkOption {
      type = lib.types.str;
      default = "jupiteros-arcade";
      description = "Pegasus theme name (must be installed in user's themes dir)";
    };

    # Emulator mappings per collection type
    emulators = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        dosbox = "dosbox-staging";
        dosbox-x = "dosbox-x";
        retroarch = "retroarch";
        vice = "vice";
        ppsspp = "ppsspp";
        pcsx2 = "pcsx2";
        dolphin = "dolphin-emu";
        ryujinx = "ryujinx";
      };
      description = "Emulator binary names per platform";
    };

    # Myrient mirror base URLs for 1G1R downloads
    mirrors = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "https://myrient.erista.me/files"
        "https://archive.org/download"
      ];
      description = "Mirror bases for 1G1R ROM downloads (tried in order)";
    };
  };

  config = lib.mkIf cfg.enable {
    # --- NFS mount of europa's /tank/archive/retro ----------------------------
    # Read-only, soft mount so a dead NAS doesn't hang the kiosk.
    # automount + idle-timeout so the mount only exists while in use.
    fileSystems.${cfg.mountPoint} = {
      device = "${cfg.nfsHost}:${cfg.nfsPath}";
      fsType = "nfs";
      options = [
        "ro"
        "noatime"
        "soft"
        "intr"
        "noauto"
        "x-systemd.automount"
        "x-systemd.idle-timeout=10min"
        "x-systemd.mount-timeout=30"
      ];
    };

    # --- Cache directories ----------------------------------------------------
    # Ephemeral /tmp cache (tmpfs, cleared on reboot)
    systemd.tmpfiles.rules = [
      "d ${cfg.tmpCacheDir} 0755 gamer users -"
      "d ${cfg.persistentCacheDir} 0755 gamer users -"
      "d /home/${cfg.sessionUser}/.config/pegasus-frontend/themes 0755 gamer users -"
      "L+ /home/${cfg.sessionUser}/.config/pegasus-frontend/themes/jupiteros-arcade - - - - ${jupiterArcadeTheme}"
      "L+ /usr/local/bin/pegasus-rom-launch - - - - /etc/pegasus-rom-launch"
    ];

    # Persistent cache survives impermanence wipe via extraDirectories
    jupiter.core.impermanence.extraDirectories = [ cfg.persistentCacheDir ];

    # --- Packages: Pegasus frontend, game loader, theme, emulators ------------------
    environment.systemPackages = with pkgs; [
      pegasus-frontend
      bubbleteaGameLoader
      jupiterArcadeTheme
      retroarch
      dosbox-staging
      dosbox-x
      vice
      scummvm
      pcem
      ppsspp
      pcsx2
      dolphin-emu
      ryujinx
      # RetroArch cores for various systems (installed via retroarch.withCores)
      (retroarch.withCores (cores: [
        cores.nestopia      # NES
        cores.snes9x        # SNES
        cores.gambatte      # GB/GBC
        cores.mgba          # GBA
        cores.mupen64plus_next # N64
        cores.melonDS       # DS
        cores.duckstation   # PS1
        cores.yabause       # Saturn
        cores.flycast       # Dreamcast
        cores.uae           # Amiga
        cores.xemu          # Xbox
        cores.gsplus        # Apple IIGS
        cores.gargoyle      # Interactive Fiction
      ]))
      # Additional emulators can be added per-collection
    ];

    # --- Pegasus configuration (seeded into gamer user's home) ----------------
    # Pegasus reads collections from collections.directory and assets from
    # assets.directory. The launcher.script is invoked per-game.
    users.users.${cfg.sessionUser} = {
      initialHashedPassword = "!"; # login via HA only
      extraGroups = [ "video" "render" "input" "audio" ];
    };

    # Seed Pegasus config on first launch (preserves user edits via impermanence)
    systemd.services.pegasus-config-seed = {
      description = "Seed Pegasus config (collections + assets dirs + launcher) for ${cfg.sessionUser} user";
      path = [ pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        User = "${cfg.sessionUser}";
        Group = "users";
      };
      script = ''
        set -eu
        CONFIG_DIR="''${XDG_CONFIG_HOME:-/home/${cfg.sessionUser}/.config}/pegasus-frontend"
        mkdir -p "$CONFIG_DIR"

        # game_dirs.txt: where Pegasus finds collections (one per line)
        GAME_DIRS="$CONFIG_DIR/game_dirs.txt"
        if [ ! -f "$GAME_DIRS" ]; then
          cat > "$GAME_DIRS" <<'EOF'
# Seeded by jupiterOS arcade module. Safe to edit; changes persist via impermanence.
${cfg.pegasusCollectionsDir}
EOF
        fi

        # settings.txt: launcher + assets directory
        SETTINGS="$CONFIG_DIR/settings.txt"
        if [ ! -f "$SETTINGS" ]; then
          cat > "$SETTINGS" <<'EOF'
# Seeded by jupiterOS arcade module. Safe to edit; changes persist via impermanence.
collections.directory=${cfg.pegasusCollectionsDir}
assets.directory=${cfg.pegasusAssetsDir}
launcher.script=/usr/local/bin/pegasus-rom-launch
general.theme=themes/${cfg.theme}
EOF
        fi

        # Ensure theme symlink exists in user's themes dir
        THEMES_DIR="$CONFIG_DIR/themes"
        mkdir -p "$THEMES_DIR"
        if [ ! -L "$THEMES_DIR/${cfg.theme}" ]; then
          ln -sf "${pkgs.pegasus-frontend}/share/pegasus-frontend/themes/${cfg.theme}" "$THEMES_DIR/${cfg.theme}" 2>/dev/null || true
        fi
      '';
    };

    # Allow the session user to run the extraction helper as root with no password.
    # --- Install launcher script to /usr/local/bin ----------------------------
    environment.etc."pegasus-rom-launch".source = cfg.launcherScript;
  };
}