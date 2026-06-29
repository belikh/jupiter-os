# Dual-session dashboard: run the kiosk on one VT and a Bazzite-style gaming
# session on another, switchable on the fly.
#
# Both sessions stay alive simultaneously, each as its own logind-managed
# graphical session pinned to a virtual terminal. systemd-logind hands DRM
# master between them whenever the active VT changes (the same mechanism as
# fast-user-switching), so flipping is just `chvt` to the other VT.
#
#   * Kiosk  (default VT 6): the existing Cage + Chromium dashboard, reusing
#     the host's `services.cage.program`/`user` so there's a single source.
#   * Gaming (default VT 7): a gamescope session running Steam's gamepad UI,
#     backed by the jupiter.gaming.bazzite software stack.
#
# Toggle with the installed `jupiter-mode {dashboard|gaming|toggle}` command
# (over SSH as root, since chvt needs CAP_SYS_TTY_CONFIG) or, with a keyboard
# attached, the usual Ctrl+Alt+F<n>.
{
  config,
  pkgs,
  lib,
  ...
}:

with lib;
let
  cfg = config.jupiter.dashboardGaming;

  # Reuse the host's kiosk command/user instead of duplicating the Chromium
  # invocation (and all its perf flags) that lives in services.cage.
  kioskProgram = config.services.cage.program;
  kioskUser = config.services.cage.user;

  # Launch the gaming session through current-system's PATH so it always
  # resolves the wrapped `steam`/`gamescope` from programs.steam/programs.gamescope.
  gamingLauncher = pkgs.writeShellScript "jupiter-gaming-session" ''
    export PATH=/run/current-system/sw/bin:$PATH
    exec ${cfg.gaming.command}
  '';

  # Shared logind/VT wiring for a session bound to a single virtual terminal,
  # modelled on nixpkgs' services.cage. PAMName + startSession make pam_systemd
  # register a seat session on the VT, which is what grants DRM master.
  vtSession = vt: {
    after = [
      "systemd-user-sessions.service"
      "systemd-logind.service"
      "getty@tty${toString vt}.service"
    ];
    conflicts = [
      "getty@tty${toString vt}.service"
      "autovt@tty${toString vt}.service"
    ];
    wantedBy = [ "multi-user.target" ];
    restartIfChanged = true;
    serviceConfig = {
      TTYPath = "/dev/tty${toString vt}";
      TTYReset = true;
      TTYVHangup = true;
      TTYVTDisallocate = true;
      StandardInput = "tty-fail";
      StandardOutput = "journal";
      StandardError = "journal";
      UtmpIdentifier = "tty${toString vt}";
      UtmpMode = "user";
      Restart = "always";
      RestartSec = 1;
    };
  };

  modeTool = pkgs.writeShellScriptBin "jupiter-mode" ''
    set -euo pipefail
    kiosk=${toString cfg.kiosk.vt}
    game=${toString cfg.gaming.vt}
    cur=$(${pkgs.kbd}/bin/fgconsole 2>/dev/null || echo "")
    case "''${1:-toggle}" in
      dashboard|kiosk) tgt=$kiosk ;;
      gaming|game|steam) tgt=$game ;;
      toggle|"")
        if [ "$cur" = "$game" ]; then tgt=$kiosk; else tgt=$game; fi ;;
      *) echo "usage: jupiter-mode [dashboard|gaming|toggle]" >&2; exit 1 ;;
    esac
    exec ${pkgs.kbd}/bin/chvt "$tgt"
  '';

  defaultVt = if cfg.defaultMode == "gaming" then cfg.gaming.vt else cfg.kiosk.vt;
in
{
  options.jupiter.dashboardGaming = {
    enable = mkEnableOption "dual-VT dashboard + Bazzite gaming session with a runtime toggle";

    kiosk = {
      vt = mkOption {
        type = types.ints.between 1 12;
        default = 6;
        description = "Virtual terminal the Cage/Chromium dashboard runs on.";
      };
    };

    gaming = {
      vt = mkOption {
        type = types.ints.between 1 12;
        default = 7;
        description = "Virtual terminal the gamescope/Steam session runs on.";
      };

      user = mkOption {
        type = types.str;
        default = "gamer";
        description = "User that owns the Steam install and runs the gaming session.";
      };

      command = mkOption {
        type = types.str;
        default = "gamescope --steam -e -- steam -gamepadui";
        description = ''
          Session command for the gaming VT. Runs with current-system's PATH so
          `gamescope`/`steam` resolve to the programs.* wrappers. Defaults to
          Steam's gamepad (Deck) UI inside a gamescope embedded session.
        '';
      };
    };

    defaultMode = mkOption {
      type = types.enum [
        "dashboard"
        "gaming"
      ];
      default = "dashboard";
      description = "Which session is foreground at boot.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.kiosk.vt != cfg.gaming.vt;
        message = "jupiter.dashboardGaming: kiosk.vt and gaming.vt must differ.";
      }
    ];

    # Pull in the Bazzite software stack (Steam + Proton-GE, gamescope, gamemode,
    # MangoHud, …). Stock kernel/Mesa: this is a low-power Intel kiosk on ZFS, not
    # a CachyOS box, and gaming mode is our own VT-pinned session below.
    jupiter.gaming.bazzite = {
      enable = true;
      gpu = "intel";
      user = cfg.gaming.user;
      cachyOsKernel = mkDefault false;
      mesaGit = mkDefault false;
      gamingMode.enable = false;
    };

    # Take over session management: the stock services.cage runs on tty1; we run
    # our own VT-pinned kiosk instead (reusing its program/user).
    services.cage.enable = mkForce false;

    users.users.${cfg.gaming.user} = {
      isNormalUser = true;
      extraGroups = [
        "video"
        "render"
        "input"
        "audio"
      ];
    };

    systemd.services.jupiter-kiosk = mkMerge [
      (vtSession cfg.kiosk.vt)
      {
        description = "Cage/Chromium dashboard kiosk (VT ${toString cfg.kiosk.vt})";
        serviceConfig = {
          ExecStart = "${pkgs.cage}/bin/cage -- ${kioskProgram}";
          User = kioskUser;
          PAMName = "jupiter-kiosk";
        };
      }
    ];

    systemd.services.jupiter-gaming = mkMerge [
      (vtSession cfg.gaming.vt)
      {
        description = "gamescope/Steam gaming session (VT ${toString cfg.gaming.vt})";
        serviceConfig = {
          ExecStart = "${gamingLauncher}";
          User = cfg.gaming.user;
          PAMName = "jupiter-gaming";
        };
      }
    ];

    # pam_systemd on each session => a seat session on its VT => DRM master
    # handoff on VT switch.
    security.pam.services.jupiter-kiosk.startSession = true;
    security.pam.services.jupiter-gaming.startSession = true;

    # Land on the configured default session once both VTs are up.
    systemd.services.jupiter-default-vt = {
      description = "Select the boot-default dashboard/gaming VT";
      after = [
        "jupiter-kiosk.service"
        "jupiter-gaming.service"
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.kbd}/bin/chvt ${toString defaultVt}";
      };
    };

    environment.systemPackages = [ modeTool ];
  };
}
