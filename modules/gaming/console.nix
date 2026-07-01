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
# Attach it to ANY host by flipping `jupiter.gaming.console.enable = true;`.
# The jovian + chaotic modules are injected for every host in flake.nix, so the
# options below resolve everywhere; nothing here activates until `enable` is set.
# The CachyOS kernel is actually a fleet-wide default (modules/common.nix), and
# its sched-ext scheduler is a general per-host choice (jupiter.core.scheduler,
# modules/core/scheduler.nix) — this module just defaults that scheduler to the
# gaming-tuned scx_lavd when the gaming profile is on.
#
# Two ideas are borrowed from GLF-OS (the French gaming NixOS distro):
#   * `apps.<name>` — a data-driven per-application toggle catalogue (see
#     `appCatalog`). Enabling the profile gives the full software stack; any one
#     app can be switched off, the "modularity" GLF exposes via its customizer.
#   * `peripherals` — controllers, sim-racing wheels, drawing tablets and RGB
#     gear that work from first boot with no manual udev/kernel wiring.
# Controllers and every app default on; wheels/tablet/RGB are opt-in.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.jupiter.gaming.console;
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

  # GLF-OS-style feature catalogue: this single attrset is the source of truth
  # for both the per-app `apps.<name>` toggles and their package wiring. The
  # core runtime (Steam, gamescope, gamemode, Proton-GE) is always on with the
  # profile; everything here is optional and individually switchable. Anything
  # that is more than a package set (Steam, gamescope, peripherals) is wired
  # explicitly in `config` below rather than living in the catalogue.
  appCatalog = {
    lutris = {
      description = "Lutris — multi-store game manager";
      packages = with pkgs; [ lutris ];
    };
    heroic = {
      description = "Heroic — Epic / GOG / Amazon launcher";
      packages = with pkgs; [ heroic ];
    };
    minecraft = {
      description = "Prism Launcher (Minecraft)";
      packages = with pkgs; [ prismlauncher ];
    };
    wine = {
      description = "Wine/Proton prefix tooling (Bottles, ProtonUp-Qt, protontricks, winetricks)";
      packages = with pkgs; [
        bottles
        protonup-qt
        protontricks
        winetricks
        steam-run
      ];
    };
    overlay = {
      description = "In-game overlay & post-processing (MangoHud, vkBasalt, GOverlay)";
      packages = with pkgs; [
        mangohud
        vkbasalt
        goverlay
      ];
    };
    modManager = {
      description = "r2modman — game mod manager";
      packages = with pkgs; [ r2modman ];
    };
    capture = {
      description = "OBS Studio + low-overhead Vulkan game capture";
      packages = with pkgs; [
        obs-studio
        obs-studio-plugins.obs-vkcapture
      ];
    };
    diagnostics = {
      description = "Vulkan / Mesa diagnostic tools";
      packages = with pkgs; [
        vulkan-tools
        mesa-demos
      ];
    };
    pcsx2 = {
      description = "PCSX2 (chaotic-nyx git build) — PS2 emulator";
      packages = with pkgs; [ pcsx2_git ];
      default = false;
    };
    shadps4 = {
      description = "shadPS4 (chaotic-nyx git build) — PS4 emulator";
      packages = with pkgs; [ shadps4_git ];
      default = false;
    };
  };

  # Packages for every app whose toggle is on.
  enabledAppPackages = lib.concatMap (
    name: lib.optionals cfg.apps.${name} appCatalog.${name}.packages
  ) (lib.attrNames appCatalog);
in
{
  options.jupiter.gaming.console = {
    enable = lib.mkEnableOption "Bazzite-style gaming stack (Jovian gaming mode + chaotic CachyOS)";

    gpu = lib.mkOption {
      type = lib.types.enum [
        "amd"
        "intel"
        "nvidia"
      ];
      default = "amd";
      description = "Primary GPU vendor. Drives driver and 32-bit graphics setup.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "io";
      description = "User that owns the Steam install and auto-logs into gaming mode.";
    };

    cachyOsKernel = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Use the CachyOS kernel (linuxPackages_cachyos) from chaotic-nyx.
        Set to false on ZFS-root hosts if the kernel outpaces OpenZFS support,
        which would otherwise fail the build.
      '';
    };

    mesaGit = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Use bleeding-edge Mesa (chaotic.mesa-git), matching Bazzite's shipping Mesa.";
    };

    gamingMode = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Enable the SteamOS-like gamescope "gaming mode" session (Jovian). When
          false you still get the full gaming software stack on a normal desktop;
          when true the host gains a boot-to-Steam console/handheld experience.
        '';
      };

      autoStart = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Boot straight into gaming mode (autologin the session).";
      };

      desktopSession = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = inferredDesktopSession;
        defaultText = lib.literalExpression ''"niri"/"gnome" inferred from jupiter.desktop.compositor'';
        description = "Desktop session Steam's 'Switch to Desktop' hands off to (null disables the button).";
      };
    };

    decky.enable = lib.mkEnableOption "Decky Loader (Steam plugin manager)";

    steamdeck.enable = lib.mkEnableOption "Steam Deck / handheld hardware quirks (Jovian devices.steamdeck)";

    # Per-application toggles, generated from `appCatalog`. Default on unless
    # the catalogue entry sets `default = false` (e.g. niche emulators), so
    # enabling the profile installs the full stack; flip any to slim it down
    # (GLF-OS's à-la-carte modularity, expressed as plain options).
    apps = lib.mapAttrs (
      _name: spec:
      lib.mkOption {
        type = lib.types.bool;
        default = spec.default or true;
        description = "Install ${spec.description}.";
      }
    ) appCatalog;

    # Game peripherals that work from first boot — the feature GLF-OS is known
    # for. steam-hardware alone only covers Steam Controllers/Deck; this widens
    # it to common pads, wheels, tablets and RGB gear with no manual wiring.
    peripherals = {
      controllers = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Broaden game-controller support beyond steam-hardware's defaults:
          Xbox One / Series pads over Bluetooth (xpadneo) and the official
          wireless dongle / wired pads (xone), plus a udev rule that stops the
          DualSense/DualShock touchpad firing phantom mouse clicks mid-game.
          DualShock / DualSense and Switch Pro pads already work via in-tree
          kernel drivers + Bluetooth.
        '';
      };

      racingWheels = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Sim-racing wheel support: the force-feedback new-lg4ff driver for
          Logitech wheels, plus Oversteer to tune them, Solaar for Logitech
          device management, and linuxConsoleTools (jstest) for calibration.
          (Fanatec's hid-fanatec kernel driver is out-of-tree and not vendored
          here, unlike GLF-OS which ships it — Oversteer still configures any
          supported wheel the kernel exposes.)
        '';
      };

      openrgb = lib.mkEnableOption "OpenRGB daemon + GUI for RGB peripheral / LED control";

      drawingTablet = lib.mkEnableOption "OpenTabletDriver support for drawing tablets";
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Additional gaming-related packages to install (beyond the app catalogue).";
    };
  };

  config = lib.mkIf cfg.enable {
    # --- Kernel & schedulers (chaotic / CachyOS) -----------------------------
    boot.kernelPackages = lib.mkIf cfg.cachyOsKernel pkgs.linuxPackages_cachyos;

    # sched-ext userspace scheduler, via the general jupiter.core.scheduler
    # module (modules/core/scheduler.nix) rather than setting services.scx
    # directly, so a host can override the scheduler choice independently of
    # the gaming profile. scx_lavd is tuned for low-latency, interactive/
    # gaming workloads — the right default here, but `mkDefault` lets a host
    # that's already set jupiter.core.scheduler win.
    jupiter.core.scheduler = lib.mkIf cfg.cachyOsKernel {
      enable = lib.mkDefault true;
      name = lib.mkDefault "scx_lavd";
    };

    # ntsync gives Proton/Wine a fast in-kernel sync primitive (Bazzite default).
    boot.kernelModules = [ "ntsync" ];

    # --- Mesa (chaotic) ------------------------------------------------------
    chaotic.mesa-git.enable = lib.mkIf cfg.mesaGit (lib.mkDefault true);

    # --- Gaming mode session (Jovian) ----------------------------------------
    jovian = {
      steam = lib.mkIf cfg.gamingMode.enable {
        enable = true;
        user = cfg.user;
        autoStart = cfg.gamingMode.autoStart;
        desktopSession = cfg.gamingMode.desktopSession;
      };
      devices.steamdeck.enable = cfg.steamdeck.enable;
      decky-loader.enable = cfg.decky.enable;
    };

    # --- Steam, gamescope, gamemode (the always-on core runtime) -------------
    programs.steam = {
      enable = true;
      gamescopeSession.enable = true;
      remotePlay.openFirewall = true;
      dedicatedServer.openFirewall = true;
      # CachyOS-patched Proton (chaotic-nyx), pairing with the cachyOsKernel /
      # scx scheduler choice above for a consistent CachyOS-stack story.
      extraCompatPackages = [ pkgs.proton-cachyos ];
    };

    programs.gamescope = {
      enable = true;
      package = pkgs.gamescope_git;
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
    services.xserver.videoDrivers = lib.mkIf (cfg.gpu == "nvidia") [ "nvidia" ];
    hardware.nvidia = lib.mkIf (cfg.gpu == "nvidia") {
      modesetting.enable = true;
      open = lib.mkDefault true; # open kernel modules; fine for Turing+ GPUs
      nvidiaSettings = true;
    };
    hardware.amdgpu.initrd.enable = lib.mkIf (cfg.gpu == "amd") (lib.mkDefault true);

    # --- Performance tuning (mirrors Bazzite's defaults) ---------------------
    zramSwap = {
      enable = lib.mkDefault true;
      algorithm = lib.mkDefault "zstd";
    };

    boot.kernel.sysctl = {
      # Required by many modern games / Proton (e.g. Hogwarts Legacy, CS2).
      # mkOverride 900, not mkDefault: nixpkgs' own sysctl.nix sets this same
      # key via mkDefault (priority 1000), so two mkDefaults here would tie
      # and fail as "defined multiple times" — mkOverride 900 breaks that
      # tie in our favor while still letting a host mkForce/mkOverride
      # something lower to win over us.
      "vm.max_map_count" = lib.mkOverride 900 2147483642;
      # Improve responsiveness under memory pressure.
      "vm.swappiness" = lib.mkDefault 10;
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
    hardware.bluetooth.enable = lib.mkDefault true;

    # Xbox controllers: xpadneo (Bluetooth) + xone (official dongle / wired).
    hardware.xpadneo.enable = lib.mkIf cfg.peripherals.controllers (lib.mkDefault true);
    hardware.xone.enable = lib.mkIf cfg.peripherals.controllers (lib.mkDefault true);

    # The PlayStation pad exposes its touchpad as a mouse, which fires phantom
    # clicks mid-game; mask it the way GLF-OS does. (DualShock 4 + DualSense.)
    services.udev.extraRules = lib.mkIf cfg.peripherals.controllers ''
      ATTRS{name}=="Sony Interactive Entertainment Wireless Controller Touchpad", ENV{LIBINPUT_IGNORE_DEVICE}="1"
      ATTRS{name}=="Sony Interactive Entertainment DualSense Wireless Controller Touchpad", ENV{LIBINPUT_IGNORE_DEVICE}="1"
      ATTRS{name}=="Wireless Controller Touchpad", ENV{LIBINPUT_IGNORE_DEVICE}="1"
      ATTRS{name}=="DualSense Wireless Controller Touchpad", ENV{LIBINPUT_IGNORE_DEVICE}="1"
    '';

    # Sim-racing wheels — force-feedback Logitech (new-lg4ff). Oversteer and
    # Solaar ship udev rules of their own, so devices are usable without manual
    # permission setup.
    hardware.new-lg4ff.enable = lib.mkIf cfg.peripherals.racingWheels (lib.mkDefault true);
    services.udev.packages = lib.mkIf cfg.peripherals.racingWheels (
      with pkgs;
      [
        oversteer
        solaar
      ]
    );

    # Drawing tablets and RGB lighting control.
    hardware.opentabletdriver.enable = lib.mkIf cfg.peripherals.drawingTablet true;
    services.hardware.openrgb = lib.mkIf cfg.peripherals.openrgb {
      enable = true;
      # chaotic-nyx git build — tracks new device support faster than nixpkgs.
      package = pkgs.openrgb_git;
    };

    # --- The gaming app stack (catalogue toggles + peripheral userland) ------
    environment.systemPackages =
      enabledAppPackages
      ++ lib.optionals cfg.peripherals.racingWheels (
        with pkgs;
        [
          oversteer # racing-wheel configuration GUI
          solaar # Logitech device manager (pairing, firmware, battery)
          linuxConsoleTools # jstest / ffmvforce for joystick calibration & FFB test
        ]
      )
      ++ cfg.extraPackages;

    # 32-bit OpenGL/Vulkan + unfree (Steam) need to be allowed.
    nixpkgs.config.allowUnfree = true;
  };
}
