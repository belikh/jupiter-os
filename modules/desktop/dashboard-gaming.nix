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
#
# Home Assistant control: via jupiter.services.haAgent's backend-launcher
# (ha-linux-agent), not a bespoke MQTT script. `jupiter-mode` itself needs
# CAP_SYS_TTY_CONFIG, which the unprivileged agent (systemd --user, runs as
# io) doesn't have — so rather than teaching the agent a new "run chvt"
# primitive (which would widen its command surface beyond "systemctl
# start/stop an allowlisted unit"), the switch action stays exactly that:
# two tiny root-run oneshot units below (jupiter-mode-dashboard.service /
# jupiter-mode-gaming.service) do the actual chvt, and a narrowly-scoped
# polkit rule lets io start (only start) exactly those two units without an
# interactive auth prompt. Neither jupiter-kiosk nor jupiter-gaming is ever
# stopped by this — both sessions stay resident, exactly as before.
#
# Known simplification vs. the mechanism this replaced: each profile's
# paired binary_sensor reflects `systemctl is-active`, which for a
# oneshot unit is only momentarily ON while `jupiter-mode` runs, not a
# sticky "current mode" indicator. Good enough for "press to switch";
# accurate live-mode reporting (matching the old select entity) would need
# a proper VT-state sensor and is left as a follow-up.
{
  config,
  pkgs,
  lib,
  ...
}:

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

  ha = cfg.homeAssistant;
in
{
  options.jupiter.dashboardGaming = {
    enable = lib.mkEnableOption "dual-VT dashboard + Bazzite gaming session with a runtime toggle";

    kiosk = {
      vt = lib.mkOption {
        type = lib.types.ints.between 1 12;
        default = 6;
        description = "Virtual terminal the Cage/Chromium dashboard runs on.";
      };
    };

    gaming = {
      vt = lib.mkOption {
        type = lib.types.ints.between 1 12;
        default = 7;
        description = "Virtual terminal the gamescope/Steam session runs on.";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "gamer";
        description = "User that owns the Steam install and runs the gaming session.";
      };

      command = lib.mkOption {
        type = lib.types.str;
        default = "gamescope --steam -e -- steam -gamepadui";
        description = ''
          Session command for the gaming VT. Runs with current-system's PATH so
          `gamescope`/`steam` resolve to the programs.* wrappers. Defaults to
          Steam's gamepad (Deck) UI inside a gamescope embedded session.
        '';
      };
    };

    defaultMode = lib.mkOption {
      type = lib.types.enum [
        "dashboard"
        "gaming"
      ];
      default = "dashboard";
      description = "Which session is foreground at boot.";
    };

    homeAssistant.enable = lib.mkEnableOption "Home Assistant control via jupiter.services.haAgent's backend-launcher (two switches: Switch to Dashboard / Switch to Gaming)";
  };

  config = lib.mkIf cfg.enable {
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
      cachyOsKernel = lib.mkDefault false;
      mesaGit = lib.mkDefault false;
      gamingMode.enable = false;
    };

    # Take over session management: the stock services.cage runs on tty1; we run
    # our own VT-pinned kiosk instead (reusing its program/user).
    services.cage.enable = lib.mkForce false;

    users.users.${cfg.gaming.user} = {
      isNormalUser = true;
      extraGroups = [
        "video"
        "render"
        "input"
        "audio"
      ];
    };

    systemd.services.jupiter-kiosk = lib.mkMerge [
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

    systemd.services.jupiter-gaming = lib.mkMerge [
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

    # --- Home Assistant control, via jupiter.services.haAgent -----------------
    # Two root-run oneshot units that do nothing but `jupiter-mode <mode>` —
    # this is the whole reason they're separate from jupiter-kiosk/jupiter-gaming:
    # backend-launcher only ever starts/stops a named unit, and starting these
    # never touches the two resident session units above.
    systemd.services.jupiter-mode-dashboard = lib.mkIf ha.enable {
      description = "Switch the active VT to the dashboard kiosk";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${modeTool}/bin/jupiter-mode dashboard";
      };
    };

    systemd.services.jupiter-mode-gaming = lib.mkIf ha.enable {
      description = "Switch the active VT to the gaming session";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${modeTool}/bin/jupiter-mode gaming";
      };
    };

    # ha-linux-agent runs as an unprivileged systemd --user service (user io)
    # and `systemctl start` on a *system* unit is normally polkit-gated —
    # scope this as narrowly as the units it grants: io, these two unit
    # names, start only (not stop/restart/anything else).
    #
    # security.polkit.enable is required for extraConfig below to do
    # anything — found live in VM testing, where a minimal host had no
    # other module incidentally pulling polkit in (on a real host it's
    # normally already on transitively, e.g. via bazzite.nix's
    # hardware.bluetooth.enable, but that's an accident of what else is
    # configured, not a real dependency this module should lean on).
    security.polkit.enable = lib.mkIf ha.enable true;

    security.polkit.extraConfig = lib.mkIf ha.enable ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            subject.user == "io") {
          var unit = action.lookup("unit");
          var verb = action.lookup("verb");
          if (verb == "start" &&
              (unit == "jupiter-mode-dashboard.service" || unit == "jupiter-mode-gaming.service")) {
            return polkit.Result.YES;
          }
        }
      });
    '';

    jupiter.services.haAgent = lib.mkIf ha.enable {
      enable = true;
      launcherApps = [
        {
          id = "dashboard";
          name = "Switch to Dashboard";
          unit = "jupiter-mode-dashboard.service";
          scope = "system";
          icon = "mdi:monitor-dashboard";
        }
        {
          id = "gaming";
          name = "Switch to Gaming";
          unit = "jupiter-mode-gaming.service";
          scope = "system";
          icon = "mdi:gamepad-variant";
        }
      ];
    };
  };
}
