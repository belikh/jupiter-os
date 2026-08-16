{
  config,
  lib,
  pkgs,
  ...
}:

# Arcade appliance session — boots STRAIGHT into the jupiterOS Arcade.
#
# The kiosks run the arcade as one switchable mode of a dashboard appliance
# (modules/desktop/dashboard-gaming.nix): cage shows the HA dashboard, and a
# Home Assistant select flips tty1 into `jupiter-arcade.service` on demand.
# That module is deliberately NOT reused on arcade-only hosts because pulling
# it in drags the whole kiosk gaming stack along:
#
#   * jupiter.gaming.console with gamingMode.enable=true — Steam, the Jovian
#     session machinery, its overlay (flake.nix applies it only for console
#     hosts), and a HARD networking.networkmanager.enable, which is dangerous
#     on hosts whose root hangs off the network (callisto's iSCSI root: NM
#     would adopt and possibly reconfigure the very NIC the root filesystem
#     I/O flows over, see hosts/callisto/configuration.nix).
#   * cage + polkit + ha-agent wiring for a dashboard this host doesn't have.
#
# This module instead runs the SAME session dashboard-gaming generates for
# kiosks — `gamescope -f -- pegasus-fe` as a start/stoppable system service
# on tty1 with pam_systemd seat wiring — minus all of the above, and makes it
# the boot default (wantedBy graphical.target). Pegasus itself, the gamer
# user's config seeding and the theme come from modules/desktop/arcade.nix;
# the collections (cartridges/exodos) attach their mount/metadata deps to the
# same `jupiter-arcade.service` unit name from their own modules.
#
# gamescope is nixpkgs' own (programs.gamescope with the cap_sys_nice
# wrapper), NOT jovian's: flake.nix only applies jovian's overlay on
# jupiter.gaming.console hosts, and staying off it keeps this closure plain
# nixpkgs — same rationale console.nix gives for its non-gamingMode path.
#
# sessionOnTty1/mkLauncher below are lifted from dashboard-gaming.nix (same
# TTY/DRM/PAM semantics; capsh --noamb keeps pam_systemd's CAP_WAKE_ALARM out
# of bubblewrap sandboxes). Keep the two in sync if the session wiring ever
# changes shape.
#
# First consumer: callisto (the fleet build server + MQTT broker doubles as
# the office arcade, HDMI display on its UHD 630 iGPU).

let
  cfg = config.jupiter.arcadeConsole;

  # See the header note in dashboard-gaming.nix for the rationale of each
  # line (PATH so programs.* wrappers resolve; XDG_RUNTIME_DIR/DBUS because a
  # plain system service lacks the pam_systemd session env; capsh --noamb so
  # nothing downstream inherits CAP_WAKE_ALARM).
  mkLauncher = pkgs.writeShellScript "jupiter-arcade-console-session" ''
    export PATH=/run/current-system/sw/bin:$PATH
    export XDG_RUNTIME_DIR="/run/user/$(id -u ${cfg.sessionUser})"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    exec ${pkgs.libcap}/bin/capsh --noamb -- -c 'exec gamescope -f -- pegasus-fe'
  '';

  # A start/stoppable system unit that can grab DRM master on tty1 — same
  # wiring as nixpkgs' services.cage / dashboard-gaming.nix's sessionOnTty1.
  # The cage-tty1 conflict is inert on hosts without cage and harmless
  # insurance on one that ever gains it. NOTE: deliberately NO
  # ConditionPathExists=/dev/tty1 here (unlike dashboard-gaming's on-demand
  # kiosk units): this unit starts at BOOT via graphical.target, and on
  # callisto's iSCSI-root boot systemd recorded the condition as failed at
  # job-dequeue time even with /dev/tty1 present (kernel VT devices always
  # exist), silently skipping the session. A condition that can false-
  # negative on the boot path is worse than no condition.
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
    # switch-to-configuration normally stops+restarts a unit whose definition
    # changed; a stop of this session costs the full stop timeout (gamescope
    # ignores SIGTERM, see TimeoutStopSec) and leaves the appliance dark after
    # every deploy (observed 2026-08-16: six switches, six dead sessions).
    # Let a changed unit file apply at the next organic restart instead.
    stopIfChanged = false;
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
      # gamescope does not exit on SIGTERM while its children tear down, so
      # the default 90s stop timeout ends in SIGKILL + Result=timeout ~80s
      # later (observed live 2026-08-16). Bound it like Valve's own
      # gamescope-session.service (Jovian ships TimeoutStopSec=10 for the
      # same reason). Keep in sync with dashboard-gaming.nix's sessionOnTty1.
      TimeoutStopSec = 10;
    };
  };
in
{
  imports = [ ./arcade.nix ];

  options.jupiter.arcadeConsole = {
    enable = lib.mkEnableOption ''
      boot-to-arcade appliance session: gamescope + Pegasus on tty1 as the
      boot default, without the kiosk dashboard/Steam stack (no cage, no
      Home Assistant switching, no Jovian, no NetworkManager forcing)
    '';

    sessionUser = lib.mkOption {
      type = lib.types.str;
      default = "gamer";
      description = ''
        User that owns the session. Must match modules/desktop/arcade.nix's
        sessionUser (which owns the Pegasus config seeding and themes).
      '';
    };

    controllers = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Game controller support: Xbox pads over Bluetooth (xpadneo) and the
        official dongle / wired (xone), Bluetooth for wireless pads, and the
        udev rule that stops DualSense/DualShock touchpads firing phantom
        mouse clicks mid-game. Same wiring modules/gaming/console.nix gives
        the kiosks, minus Steam-specific pieces.
      '';
    };

    audioOutput = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [
        "hdmi"
        "analog"
      ]);
      default = null;
      description = ''
        Force the session's PulseAudio output to the TV (HDMI) or the
        motherboard jack/speakers. PulseAudio's own heuristics prefer the
        analog profile (its priority number is higher), so on a box whose
        display IS its speaker setup (callisto: HDMI TV, no speakers wired)
        the default routes game audio to silent built-in hardware — observed
        live 2026-08-16, analog-stereo active with an LG TV on HDMI-A-1.
        The switch is written into the shared default.pa so it survives the
        impermanent home (module-card-restore's database lives under
        ~/.config/pulse, which is not persisted). null leaves PulseAudio's
        profile/default selection untouched.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Boot default = graphical.target, which wants the session unit below.
    # Same pairing as nixpkgs' cage module (services/wayland/cage.nix sets
    # wantedBy graphical.target AND systemd.defaultUnit graphical.target):
    # without the defaultUnit flip a host with no display manager (this one)
    # boots to multi-user.target and never starts the session — found live on
    # callisto, where the unit was enabled+inactive after the first switch.
    systemd.defaultUnit = "graphical.target";

    # Pegasus + theme + per-user config seeding (game_dirs.txt from every
    # collection module contributing to jupiter.arcade.gameDirs).
    jupiter.arcade.enable = true;

    # arcade.nix sets the session user's groups + locked password; the
    # isNormalUser half normally comes from dashboard-gaming on kiosks.
    users.users.${cfg.sessionUser}.isNormalUser = true;

    # Stock nixpkgs gamescope (see header). capSysNice gives it the
    # sched-priority wrapper, matching the kiosk session's behavior closely
    # enough for an appliance (kiosks use jovian's equivalent wrapper).
    programs.gamescope = {
      enable = true;
      capSysNice = true;
    };

    # --- The session unit (same name the collection modules target) ---------
    systemd.services.jupiter-arcade = lib.mkMerge [
      sessionOnTty1
      {
        description = "jupiterOS Arcade console session (gamescope/Pegasus, tty1)";
        # The appliance difference vs the kiosks: boot straight into the
        # arcade instead of waiting for a Home Assistant select to start it.
        wantedBy = [ "graphical.target" ];
        serviceConfig = {
          ExecStart = "${mkLauncher}";
          User = cfg.sessionUser;
          PAMName = "jupiter-arcade";
        };
      }
    ];

    # pam_systemd => a logind seat session on tty1 => DRM master for
    # gamescope (same as dashboard-gaming.nix wires for the kiosk modes).
    security.pam.services.jupiter-arcade.startSession = true;

    # Move the boot-time getty off tty1 (the session's VT) onto tty2.
    # nixpkgs hardwires `systemd.targets.getty.wants = [ "autovt@tty1" ]`
    # whenever no display manager is enabled (nixos/modules/services/ttys/
    # getty.nix:174 — its own comment admits this fights compositor
    # sessions on tty1), so autovt@tty1 kept respawning during switches and
    # grabbing tty1 in the gap when jupiter-arcade restarted (observed live
    # on callisto: "new units started: autovt@tty1.service"). mkForce
    # replaces that want with tty2, matching the unit-level Conflicts above;
    # tty2 remains the rescue console (Ctrl+Alt+F2).
    systemd.targets.getty.wants = lib.mkForce [ "autovt@tty2.service" ];

    # --- Audio ---------------------------------------------------------------
    # Per-user pulseaudio: the gamer user's logind session socket-activates
    # it, so Pegasus/retroarch/dosbox get audio with no system daemon. Same
    # shape the kiosks use (modules/desktop/tcxwave-kiosk.nix).
    services.pulseaudio.enable = true;

    # HDMI TV as the output, when asked for (see audioOutput). These run at
    # the end of default.pa, after module-udev-detect has attached the card
    # and after module-card-restore/module-default-device-restore have
    # applied whatever they remember — so the explicit choice always wins,
    # fresh boot or not. The card path pins the appliance's fixed audio
    # controller (Intel PCH at 00:1f.3); HDMI profile keeps the analog mic
    # input alive for hosts that want it later.
    services.pulseaudio.extraConfig = lib.mkIf (cfg.audioOutput == "hdmi") ''
      set-card-profile alsa_card.pci-0000_00_1f.3 output:hdmi-stereo+input:analog-stereo
      set-default-sink alsa_output.pci-0000_00_1f.3.hdmi-stereo
    '';

    # --- Controllers ---------------------------------------------------------
    hardware.xpadneo.enable = lib.mkIf cfg.controllers (lib.mkDefault true);
    hardware.xone.enable = lib.mkIf cfg.controllers (lib.mkDefault true);
    # powerOnBoot: bring hci0 up unattended so a trusted (paired) controller
    # can auto-reconnect by pad-initiated advertising the moment the box
    # boots — without it the DS4 sat paired-but-unreachable until someone
    # powered the adapter by hand (observed live on callisto).
    hardware.bluetooth = lib.mkIf cfg.controllers {
      enable = lib.mkDefault true;
      powerOnBoot = lib.mkDefault true;
    };
    services.udev.extraRules = lib.mkIf cfg.controllers ''
      ATTRS{name}=="Sony Interactive Entertainment Wireless Controller Touchpad", ENV{LIBINPUT_IGNORE_DEVICE}="1"
      ATTRS{name}=="Sony Interactive Entertainment DualSense Wireless Controller Touchpad", ENV{LIBINPUT_IGNORE_DEVICE}="1"
      ATTRS{name}=="Wireless Controller Touchpad", ENV{LIBINPUT_IGNORE_DEVICE}="1"
      ATTRS{name}=="DualSense Wireless Controller Touchpad", ENV{LIBINPUT_IGNORE_DEVICE}="1"
    '';
  };
}
