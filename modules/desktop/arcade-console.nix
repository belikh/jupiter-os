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
# sessionOnTty1/mkLauncher come from modules/lib.nix — shared byte-for-byte
# with dashboard-gaming.nix (same TTY/DRM/PAM semantics; capsh --noamb keeps
# pam_systemd's CAP_WAKE_ALARM out of bubblewrap sandboxes), so the two
# cannot drift.
#
# First consumer: callisto (the fleet build server + MQTT broker doubles as
# the office arcade, HDMI display on its UHD 630 iGPU).

let
  cfg = config.jupiter.arcadeConsole;

  # Session launcher + tty1 seat wiring live in modules/lib.nix now — shared
  # byte-for-byte with dashboard-gaming.nix, so the two can never drift (the
  # old "Keep the two in sync" copies did exactly that).
  inherit (import ../lib.nix { inherit config lib pkgs; })
    mkSessionLauncher
    mkSessionOnTty1
    gamescopePrograms
    ;

  mkLauncher = mkSessionLauncher "arcade-console" cfg.sessionUser "gamescope -f -- pegasus-fe";

  # conditionOnTty1 = false: this unit starts at BOOT via graphical.target,
  # and on callisto's iSCSI-root boot systemd recorded the condition as
  # failed at job-dequeue time even with /dev/tty1 present (kernel VT
  # devices always exist), silently skipping the session. A condition that
  # can false-negative on the boot path is worse than no condition. Full
  # rationale for every other key lives in modules/lib.nix.
  sessionOnTty1 = mkSessionOnTty1 { conditionOnTty1 = false; };
in
{
  imports = [
    ./arcade.nix
    # Shared controller stack (identical wiring console.nix gives the kiosks
    # — importing it twice is idempotent, and keeps the udev rules from ever
    # being defined in two places).
    ../gaming/controllers.nix
  ];

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
      type = lib.types.nullOr (
        lib.types.enum [
          "hdmi"
          "analog"
        ]
      );
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

    # Stock nixpkgs gamescope (see header). Shared value with console.nix so
    # the two definitions can never diverge (lib.nix: gamescopePrograms).
    programs.gamescope = gamescopePrograms;

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
    # xpadneo (Bluetooth) + xone (dongle/wired), Bluetooth powered on at boot
    # so a trusted (paired) controller can auto-reconnect, and the udev rule
    # that stops DualSense/DualShock touchpads firing phantom mouse clicks
    # mid-game — all of it in the shared modules/gaming/controllers.nix
    # (same wiring the kiosks get via modules/gaming/console.nix), gated on
    # this module's controllers flag.
    jupiter.gaming.controllers.enable = lib.mkIf cfg.controllers true;
  };
}
