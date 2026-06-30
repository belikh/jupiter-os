# Bazzite-style gaming stack for NixOS.
#
# A reusable, opt-in profile that reproduces the modern (2026) Bazzite gaming
# experience using the two upstream projects that map onto it on NixOS:
#
#   * Jovian-NixOS  -> the SteamOS "gaming mode" gamescope session, Steam Deck
#                      hardware quirks, and Decky Loader.
#   * chaotic-nyx   -> the CachyOS kernel, bleeding-edge Mesa (mesa-git), the
#                      sched-ext (scx) schedulers, and gamescope_git.
#
# Attach it to ANY host by flipping `jupiter.gaming.bazzite.enable = true;`.
# The jovian + chaotic modules are injected for every host in flake.nix, so the
# options below resolve everywhere; nothing here activates until `enable` is set.
#
# Peripheral support (`jupiter.gaming.bazzite.peripherals`) is borrowed from
# GLF-OS (the French gaming NixOS distro): controllers, sim-racing wheels,
# drawing tablets and RGB gear that work from first boot, no manual udev/kernel
# wiring. Controllers are on by default; the rest are opt-in.
{
  config,
  pkgs,
  lib,
  ...
}:

with lib;
let
  cfg = config.jupiter.gaming.bazzite;
  desktop = config.jupiter.desktop;

  # When booting into gaming mode, Steam's "Switch to Desktop" needs a desktop
  # session to hand off to. Infer it from the host's chosen compositor so the
  # two stay in sync, but let the host override explicitly.
  inferredDesktopSession =
    if desktop.enable && desktop.compositor == "niri" then
      "niri"
    else if desktop.enable && desktop.compositor == "gnome" then
      "gnome"
    else
      null;
in
{
  options.jupiter.gaming.bazzite = {
    enable = mkEnableOption "Bazzite-style gaming stack (Jovian gaming mode + chaotic CachyOS)";

    gpu = mkOption {
      type = types.enum [
        "amd"
        "intel"
        "nvidia"
      ];
      default = "amd";
      description = "Primary GPU vendor. Drives driver and 32-bit graphics setup.";
    };

    user = mkOption {
      type = types.str;
      default = "io";
      description = "User that owns the Steam install and auto-logs into gaming mode.";
    };

    cachyOsKernel = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Use the CachyOS kernel (linuxPackages_cachyos) from chaotic-nyx.
        Set to false on ZFS-root hosts if the kernel outpaces OpenZFS support,
        which would otherwise fail the build.
      '';
    };

    mesaGit = mkOption {
      type = types.bool;
      default = true;
      description = "Use bleeding-edge Mesa (chaotic.mesa-git), matching Bazzite's shipping Mesa.";
    };

    gamingMode = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Enable the SteamOS-like gamescope "gaming mode" session (Jovian). When
          false you still get the full gaming software stack on a normal desktop;
          when true the host gains a boot-to-Steam console/handheld experience.
        '';
      };

      autoStart = mkOption {
        type = types.bool;
        default = true;
        description = "Boot straight into gaming mode (autologin the session).";
      };

      desktopSession = mkOption {
        type = types.nullOr types.str;
        default = inferredDesktopSession;
        defaultText = literalExpression ''"niri"/"gnome" inferred from jupiter.desktop.compositor'';
        description = "Desktop session Steam's 'Switch to Desktop' hands off to (null disables the button).";
      };
    };

    decky.enable = mkEnableOption "Decky Loader (Steam plugin manager)";

    steamdeck.enable = mkEnableOption "Steam Deck / handheld hardware quirks (Jovian devices.steamdeck)";

    # Game peripherals that work from first boot — the feature GLF-OS (the
    # French gaming NixOS distro) is known for. steam-hardware alone only
    # covers Steam Controllers/Deck; this widens it to the common pads, wheels,
    # tablets and RGB gear without the user hand-wiring kernel modules + udev.
    peripherals = {
      controllers = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Broaden game-controller support beyond steam-hardware's defaults:
          Xbox One / Series pads over Bluetooth (xpadneo) and the official
          wireless dongle / wired pads (xone). DualShock / DualSense and
          Switch Pro pads already work via in-tree kernel drivers + Bluetooth.
        '';
      };

      racingWheels = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Sim-racing wheel support the way GLF-OS ships it: the hid-fanatec
          driver for Fanatec bases and the force-feedback new-lg4ff driver for
          Logitech wheels, plus Oversteer to tune them, Solaar for Logitech
          device management, and linuxConsoleTools (jstest) for calibration.
        '';
      };

      openrgb = mkEnableOption "OpenRGB daemon + GUI for RGB peripheral / LED control";

      drawingTablet = mkEnableOption "OpenTabletDriver support for drawing tablets";
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Additional gaming-related packages to install.";
    };
  };

  config = mkIf cfg.enable {
    # --- Kernel & schedulers (chaotic / CachyOS) -----------------------------
    boot.kernelPackages = mkIf cfg.cachyOsKernel pkgs.linuxPackages_cachyos;

    # sched-ext userspace scheduler. scx_lavd is tuned for low-latency,
    # interactive/gaming workloads. Needs a sched_ext-capable kernel (CachyOS).
    services.scx = mkIf cfg.cachyOsKernel {
      enable = mkDefault true;
      scheduler = mkDefault "scx_lavd";
    };

    # ntsync gives Proton/Wine a fast in-kernel sync primitive (Bazzite default).
    boot.kernelModules = [ "ntsync" ];

    # --- Mesa (chaotic) ------------------------------------------------------
    chaotic.mesa-git.enable = mkIf cfg.mesaGit (mkDefault true);

    # --- Gaming mode session (Jovian) ----------------------------------------
    jovian = {
      steam = mkIf cfg.gamingMode.enable {
        enable = true;
        user = cfg.user;
        autoStart = cfg.gamingMode.autoStart;
        desktopSession = cfg.gamingMode.desktopSession;
      };
      devices.steamdeck.enable = cfg.steamdeck.enable;
      decky-loader.enable = cfg.decky.enable;
    };

    # --- Steam, gamescope, gamemode ------------------------------------------
    programs.steam = {
      enable = true;
      gamescopeSession.enable = true;
      remotePlay.openFirewall = true;
      dedicatedServer.openFirewall = true;
      # Glorious Eggroll Proton, the de-facto Bazzite default compat tool.
      extraCompatPackages = [ pkgs.proton-ge-bin ];
    };

    programs.gamescope = {
      enable = true;
      capSysNice = true;
    };

    programs.gamemode.enable = true;

    hardware.steam-hardware.enable = true;

    # --- Graphics drivers ----------------------------------------------------
    hardware.graphics = {
      enable = true;
      enable32Bit = true;
    };

    # Vendor-specific driver wiring.
    services.xserver.videoDrivers = mkIf (cfg.gpu == "nvidia") [ "nvidia" ];
    hardware.nvidia = mkIf (cfg.gpu == "nvidia") {
      modesetting.enable = true;
      open = mkDefault true; # open kernel modules; fine for Turing+ GPUs
      nvidiaSettings = true;
    };
    hardware.amdgpu.initrd.enable = mkIf (cfg.gpu == "amd") (mkDefault true);

    # --- Performance tuning (mirrors Bazzite's defaults) ---------------------
    zramSwap = {
      enable = mkDefault true;
      algorithm = mkDefault "zstd";
    };

    boot.kernel.sysctl = {
      # Required by many modern games / Proton (e.g. Hogwarts Legacy, CS2).
      "vm.max_map_count" = mkDefault 2147483642;
      # Improve responsiveness under memory pressure.
      "vm.swappiness" = mkDefault 10;
    };

    # Let games raise priority / use the realtime + nice rlimits.
    security.pam.loginLimits = [
      {
        domain = "@users";
        item = "nofile";
        type = "soft";
        value = "524288";
      }
      {
        domain = "@users";
        item = "nofile";
        type = "hard";
        value = "1048576";
      }
    ];

    # --- Game peripherals (controllers, wheels, tablets, RGB) ----------------
    # input-remapper lets pads/keyboards be remapped; Bluetooth covers wireless
    # controllers. Both are wanted on any gaming host.
    services.input-remapper.enable = true;
    hardware.bluetooth.enable = mkDefault true;

    # Xbox controllers: xpadneo (Bluetooth) + xone (official dongle / wired).
    hardware.xpadneo.enable = mkIf cfg.peripherals.controllers (mkDefault true);
    hardware.xone.enable = mkIf cfg.peripherals.controllers (mkDefault true);

    # Sim-racing wheels — Fanatec (hid-fanatec) and force-feedback Logitech
    # (new-lg4ff). The upstream NixOS modules also drop the udev rules and add
    # users to the `games` group, so devices are usable without manual perms.
    hardware.fanatec.enable = mkIf cfg.peripherals.racingWheels true;
    hardware.new-lg4ff.enable = mkIf cfg.peripherals.racingWheels (mkDefault true);

    # Drawing tablets and RGB lighting control.
    services.opentabletdriver.enable = mkIf cfg.peripherals.drawingTablet true;
    services.hardware.openrgb.enable = mkIf cfg.peripherals.openrgb true;

    # --- The Bazzite app stack ----------------------------------------------
    environment.systemPackages =
      with pkgs;
      [
        mangohud # in-game performance overlay
        vkbasalt # post-processing layer (sharpening, etc.)
        goverlay # MangoHud/vkBasalt GUI config
        gamescope # session compositor (chaotic overlay -> gamescope_git)
        gamemode
        lutris
        heroic # Epic / GOG / Amazon launcher
        prismlauncher # Minecraft
        bottles # Wine prefix manager
        protonup-qt # manage Proton-GE / compat tools
        protontricks
        winetricks
        steam-run
        vulkan-tools
        mesa-demos
        r2modman # mod manager
        obs-studio
        obs-studio-plugins.obs-vkcapture # low-overhead game capture
      ]
      ++ optionals cfg.peripherals.racingWheels [
        oversteer # racing-wheel configuration GUI
        solaar # Logitech device manager (pairing, firmware, battery)
        linuxConsoleTools # jstest / ffmvforce for joystick calibration & FFB test
      ]
      ++ cfg.extraPackages;

    # 32-bit OpenGL/Vulkan + unfree (Steam) need to be allowed.
    nixpkgs.config.allowUnfree = true;
  };
}
