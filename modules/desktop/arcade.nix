{
  config,
  lib,
  pkgs,
  ...
}:

# jupiterOS Arcade — Pegasus frontend with on-demand ROM loading via NFS + Minerva torrents.
#
# Architecture (per issue #30):
# - All ROMs (1G1R collections) live on europa NAS at /tank/archive/retro/games/,
#   served read-only via NFS to kiosks.
# - ROMs are fetched on-demand from Minerva .torrent files using aria2c
#   (see arcade-api HTTP service on europa:8765).
# - Pegasus metadata collections + assets served from NFS at
#   /tank/archive/retro/metadata/pegasus/
# - Launcher script (pegasus-rom-launch) dispatches:
#     * cache hit → instant launch (file already on NFS)
#     * cache miss → spawn bubbletea-game-loader TUI to download from Minerva
# - Bubble Tea TUI (bubbletea-game-loader) shows progress with cancellation support.
# - Download cache: /tank/archive/retro/games/ on europa NAS (persistent, shared via NFS).
# - Kiosks are consumers only — no timers, no API server, no DAT processing, no local ROM storage.

let
  cfg = config.jupiter.arcade;

  # Build the Bubble Tea game loader from Go source
  bubbleteaGameLoader = pkgs.buildGoModule {
    name = "bubbletea-game-loader";
    src = ../../scripts/bubbletea-game-loader;
    vendorHash = "sha256-ntYW/eWIavEyc8WtVZXb7/NwgzX9U8MxfneOGssDbFE=";
    installPhase = ''
      mkdir -p $out/bin
      cp $GOPATH/bin/bubbletea-game-loader $out/bin/ || cp bubbletea-game-loader $out/bin/
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
      default = "/tank/archive/retro";
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

    # Game directories (where Pegasus metadata files live, one per line in game_dirs.txt)
    gameDirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        cfg.pegasusCollectionsDir
      ];
      description = "Directory containing Pegasus metadata collection files (game_dirs.txt)";
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
      default = ../../scripts/pegasus-rom-launch;
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

    # Persistent caches survive impermanence wipe via extraDirectories
    jupiter.core.impermanence.extraDirectories = [
      cfg.persistentCacheDir
      "/var/cache/pegasus-torrents"
    ];

    # --- Packages: Pegasus frontend, game loader, theme, emulators ------------------
    environment.systemPackages = with pkgs; [
      pegasus-frontend
      bubbleteaGameLoader
      jupiterArcadeTheme
      retroarch
      dosbox-staging
      dosbox-x
      scummvm
      pcem
      ppsspp
      pcsx2
      dolphin-emu
      ryubing
      xterm
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
        # Pegasus expects a directory containing subdirectories, each with metadata.pegasus.txt
        # Always write to ensure path stays in sync (user can edit but gets reset on rebuild)
        GAME_DIRS="$CONFIG_DIR/game_dirs.txt"
        cat > "$GAME_DIRS" <<'EOF'
# Seeded by jupiterOS arcade module. Safe to edit; changes persist via impermanence.
EOF
        for dir in ${toString cfg.gameDirs}; do
          echo "$dir" >> "$GAME_DIRS"
        done

        # settings.txt: launcher + assets directory (uses key: value format with colon+space)
        # Append new settings if file exists (preserve user edits), otherwise create fresh
        SETTINGS="$CONFIG_DIR/settings.txt"
        if [ ! -f "$SETTINGS" ]; then
          cat > "$SETTINGS" <<'EOF'
# Seeded by jupiterOS arcade module. Safe to edit; changes persist via impermanence.
collections.directory: ${cfg.pegasusCollectionsDir}
assets.directory: ${cfg.pegasusAssetsDir}
launcher.script: /usr/local/bin/pegasus-rom-launch
general.theme: themes/${cfg.theme}
EOF
        else
          # Ensure key settings are present even if file exists
          grep -q "collections.directory" "$SETTINGS" || echo "collections.directory: ${cfg.pegasusCollectionsDir}" >> "$SETTINGS"
          grep -q "assets.directory" "$SETTINGS" || echo "assets.directory: ${cfg.pegasusAssetsDir}" >> "$SETTINGS"
          grep -q "launcher.script" "$SETTINGS" || echo "launcher.script: /usr/local/bin/pegasus-rom-launch" >> "$SETTINGS"
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

    # Symlink bubbletea-game-loader to /usr/local/bin for pegasus-rom-launch
    system.activationScripts.bubbleteaGameLoaderLink = {
      text = ''
        mkdir -p /usr/local/bin
        ln -sfn ${bubbleteaGameLoader}/bin/bubbletea-game-loader /usr/local/bin/bubbletea-game-loader
      '';
    };
  };
}