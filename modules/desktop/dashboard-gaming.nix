{
  config,
  pkgs,
  lib,
  ...
}:

# Dashboard ↔ gaming mode for the TCx Wave kiosks, switchable from Home
# Assistant. Normally the kiosk shows the Cage + Chromium dashboard; HA can
# flip it to a gamescope/Steam gaming session and back.
#
# --- Why a custom service, not Jovian's native session ---------------------
# Jovian-NixOS's gamescope "gaming mode" session is a *systemd user unit*
# (gamescope-session.service) that boots via an SDDM *autologin* into the
# gamescope-wayland session (see jovian's modules/steam/autostart.nix). SDDM
# and Cage both want to own the graphical seat / tty1, so jovian's
# autoStart=true would boot straight into gaming and fight cage. Instead we
# keep jovian's *software stack* (Steam, gamescope + its cap_sys_nice wrapper,
# Proton, the gamescope-wsi Vulkan layer) but run the session ourselves as a
# single start/stoppable SYSTEM service on a SHARED tty1, modelled on Cage's
# own PAM/logind seat wiring (the same trick the archived dual-VT design used,
# minus the second VT — only one session owns the display at a time here).
#
# --- Switching model -------------------------------------------------------
# ha-linux-agent's backend-launcher (modules/services/ha-agent.nix) exposes
# each "profile" as an HA switch and turns profile *on* into a stop-then-start
# of group-mates: starting "gaming" first best-effort-stops cage, then starts
# jupiter-gaming. We also add a systemd `Conflicts=` between the two units as a
# belt-and-suspenders backstop (the launcher's mutual exclusion is best-effort
# and sequential, not atomic). No chvt, no polkit-for-chvt, no second VT.

let
  cfg = config.jupiter.dashboardGaming;

  # Launch the gaming session through a PATH that resolves jovian's
  # cap_sys_nice gamescope wrapper (/run/wrappers/bin/gamescope, set up by
  # jovian.steam) and the programs.steam wrapper (/run/current-system/sw/bin).
  gamingLauncher = pkgs.writeShellScript "jupiter-gaming-session" ''
    export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH
    exec ${cfg.gaming.command}
  '';

  # Shared tty1 PAM/logind seat wiring — a start/stoppable system unit that can
  # grab DRM master on tty1. Modelled on nixpkgs' services.cage (and the
  # archived design's vtSession): pam_systemd registers a seat session on the
  # VT, which is what grants DRM master. tty1 is SHARED with cage (not a
  # separate VT): the launcher's group mutex stops cage before this starts, so
  # only one ever holds the display.
  sessionOnTty1 = {
    after = [
      "systemd-user-sessions.service"
      "systemd-logind.service"
      "getty@tty1.service"
    ];
    before = [ "graphical.target" ];
    conflicts = [
      "getty@tty1.service"
      "autovt@tty1.service"
      "cage-tty1.service"
    ];
    unitConfig.ConditionPathExists = "/dev/tty1";
    serviceConfig = {
      TTYPath = "/dev/tty1";
      TTYReset = true;
      TTYVHangup = true;
      TTYVTDisallocate = true;
      StandardInput = "tty-fail";
      StandardOutput = "journal";
      StandardError = "journal";
      UtmpIdentifier = "tty1";
      UtmpMode = "user";
      Restart = "always";
      RestartSec = 2;
    };
  };
in
{
  imports = [ ../gaming/console.nix ];

  options.jupiter.dashboardGaming = {
    enable = lib.mkEnableOption "Dashboard ↔ gaming mode switch for a Cage kiosk (Home Assistant controlled)";

    gaming = {
      user = lib.mkOption {
        type = lib.types.str;
        default = "gamer";
        description = ''
          User that owns the Steam install and runs the gaming session. Kept
          separate from the kiosk user so Steam's state lives in its own home
          (and gets its own impermanence persistence — see below).
        '';
      };

      command = lib.mkOption {
        type = lib.types.str;
        default = "gamescope --steam -e -- steam -gamepadui";
        description = ''
          Session command for the gaming tty. Runs with /run/wrappers/bin and
          /run/current-system/sw/bin on PATH so jovian's cap_sys_nice gamescope
          wrapper and the programs.steam wrapper resolve. Defaults to Steam's
          gamepad (Deck) UI inside a gamescope embedded session.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # --- Gaming software stack (Jovian + chaotic), NO SDDM autostart ---------
    # Stock kernel + stock Mesa: this is a low-power Intel (HD 520) kiosk on
    # ZFS, not a CachyOS box (CLAUDE.md hard rule: no custom kernels on ZFS
    # hosts; and no microarch tuning). gamingMode.autoStart = false is the
    # load-bearing bit: jovian's autoStart would enable SDDM (conflicts with
    # cage); we drive the session via jupiter-gaming.service below instead.
    jupiter.gaming.console = {
      enable = true;
      gpu = "intel";
      user = cfg.gaming.user;
      cachyOsKernel = false;
      mesaGit = false;
      gamingMode = {
        enable = true;
        autoStart = false;
      };
    };

    users.users.${cfg.gaming.user} = {
      isNormalUser = true;
      extraGroups = [
        "video"
        "render"
        "input"
        "audio"
      ];
    };

    # --- The gaming session as an on-demand system service on tty1 ----------
    # NOT wantedBy anything: cage-tty1 auto-starts at boot (dashboard by
    # default); this is started on demand by the HA "Switch to Gaming" switch.
    systemd.services.jupiter-gaming = lib.mkMerge [
      sessionOnTty1
      {
        description = "gamescope/Steam gaming session (tty1)";
        serviceConfig = {
          ExecStart = "${gamingLauncher}";
          User = cfg.gaming.user;
          PAMName = "jupiter-gaming";
        };
      }
    ];

    # pam_systemd on the session => a logind seat session on tty1 => DRM master.
    security.pam.services.jupiter-gaming.startSession = true;

    # Backstop mutual exclusion at the unit level: if anything ever starts both
    # (e.g. the launcher's best-effort stop loses a race), systemd drops the
    # loser. Appends to cage-tty1's existing conflicts list (NixOS merges).
    systemd.services.cage-tty1.conflicts = [ "jupiter-gaming.service" ];

    # --- Home Assistant control (ha-linux-agent launcher group) -------------
    # cage-tty1 (the dashboard) and jupiter-gaming share group "session":
    # turning either ON first best-effort-stops the other, so HA's switch is a
    # one-tap flip. Verfied unit name cage-tty1.service against nixpkgs' own
    # services.cage module (modules/services/wayland/cage.nix) at the pinned
    # nixpkgs rev; jupiter-gaming.service is the unit defined just above.
    jupiter.services.haAgent.launcherApps = [
      {
        id = "dashboard";
        name = "${config.networking.hostName} dashboard";
        unit = "cage-tty1.service";
        scope = "system";
        group = "session";
        icon = "mdi:monitor-dashboard";
      }
      {
        id = "gaming";
        name = "${config.networking.hostName} gaming";
        unit = "jupiter-gaming.service";
        scope = "system";
        group = "session";
        icon = "mdi:gamepad-variant";
      }
    ];

    # --- Impermanence: keep the gamer's Steam state across reboots ----------
    # Without this the impermanent kiosk root wipes Steam's login, library
    # manifest and saves on every reboot. gamescope config is small but nice to
    # keep. Game files themselves live under .local/share/Steam/steamapps.
    jupiter.core.impermanence.users.${cfg.gaming.user}.directories = [
      ".steam"
      ".local/share/Steam"
      ".config/Steam"
      ".config/gamescope"
    ];
  };
}
