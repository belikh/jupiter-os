{
  config,
  lib,
  pkgs,
  ...
}:

# Native Rust + Slint kiosk (robcoterm) — the eventual replacement for the
# Cage + Chromium stack in dashboard-kiosk.nix. Drives the eDP panel directly
# via DRM/KMS (backend-linuxkms-noseat + femtovg): no browser, no compositor.
#
# A host opts in with jupiter.robcotermKiosk.enable = true; until then this
# module is inert. It is imported by the shared tcxwave-kiosk.nix profile so
# all four TCx Wave units carry the option namespace, but cutover is per-host
# (Phase 4): a host flips enable = true AND stops importing the cage/chromium
# path. dashboard-kiosk.nix stays in-tree throughout for rollback.

let
  cfg = config.jupiter.robcotermKiosk;
in
{
  options.jupiter.robcotermKiosk = {
    enable = lib.mkEnableOption "robcoterm native Slint kiosk (replaces Cage + Chromium)";

    package = lib.mkOption {
      type = lib.types.package;
      description = ''
        The robcoterm binary derivation. Provided by the flake's
        packages.x86_64-linux.robcoterm via an injection in flake.nix mkHost,
        so host files never need to reference it directly.
      '';
    };

    haUrl = lib.mkOption {
      type = lib.types.str;
      default = "wss://iot.jupiter.au/api/websocket";
      description = ''
        Home Assistant WebSocket endpoint. Single HA instance for all four
        hosts; only the per-room entity set differs.
      '';
    };

    haTokenFile = lib.mkOption {
      type = lib.types.str;
      description = ''
        Path to the sops-decrypted HA Long-Lived Access Token for this host
        (config.sops.secrets.robcoterm_ha_token.path). Passed via systemd
        LoadCredential=, so it never appears in /proc/environ or the journal.
      '';
    };

    room = lib.mkOption {
      type = lib.types.enum [
        "bedroom"
        "kitchen"
        "office"
        "robbie"
      ];
      description = ''
        Which room's overview/detail page-set this kiosk renders. Drives the
        theme colour and the entity bindings: bedroom→amber, kitchen→green,
        office→blue, robbie→purple (matching fallout_retro_{amber,green,blue,
        purple}).
      '';
    };

    idleTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = ''
        Seconds of input inactivity before DPMS powers the panel off; the next
        touch event wakes it. Replaces the cage-era tcxwave-screen-power +
        tcxwave-touch-wake pair (wired in Phase 4).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Monofonto (the Vault-Tec display face, bundled under apps/robcoterm/
    # assets/fonts) — installed system-wide so fontconfig discovers it and
    # Slint's fontique resolves Theme.font-family = "Monofonto". Tiny (57 KB),
    # so a dedicated font derivation is cheaper than pulling the whole robcoterm
    # binary closure into fonts.packages.
    fonts.packages = [
      (pkgs.runCommand "monofonto-font" { } ''
        mkdir -p $out/share/fonts
        cp ${../../apps/robcoterm/assets/fonts/monofonto.otf} $out/share/fonts/monofonto.otf
      '')
    ];

    # robcoterm owns DRM master on /dev/dri/cardN and runs on tty1 as the
    # kiosk user (video/render/input groups). The TTY binding is load-bearing:
    # DRM page_flip returns EACCES unless the process is the active VT session
    # leader (verified on amalthea during the Phase 0 smoke — had to run via
    # openvt on a free VT to acquire master). See task.md T1.2.
    # NOTE for Phase 4 display.rs: amalthea's device is /dev/dri/card1 (not
    # card0 as task.md T4.1 assumes) — auto-detect rather than hardcode.
    systemd.services.robcoterm = {
      description = "robcoterm native Slint dashboard kiosk";
      wantedBy = [ "graphical.target" ];
      after = [ "systemd-user-sessions.service" ];

      serviceConfig = {
        Type = "simple";
        User = "kiosk";
        Group = "video";
        SupplementaryGroups = [
          "render"
          "input"
        ];
        TTYPath = "/dev/tty1";
        TTYReset = true;
        TTYVHangup = true;
        # Token reaches the binary as %d/robcoterm_ha_token (systemd's private
        # credential dir), readable only by User=kiosk. See implementation_plan
        # .md "Secret flow". The binary reads it once, zeroes the buffer.
        LoadCredential = "robcoterm_ha_token:${cfg.haTokenFile}";
        ExecStart = "${cfg.package}/bin/robcoterm --ha-url ${cfg.haUrl} --ha-token-file %d/robcoterm_ha_token --room ${cfg.room}";
      };

      # femtovg dlopens libEGL.so.1 (from libglvnd) + the mesa EGL vendor +
      # the iris_dri driver. addDriverRunpath does NOT place these on the
      # binary's RUNPATH (verified on amalthea: RUNPATH has libgbm but no
      # /run/opengl-driver/lib), so the unit must expose them explicitly.
      # /run/opengl-driver/lib is the NixOS system GL profile cage already
      # relies on; the mesa store paths cover libglvnd's dispatch lib (which
      # the profile lacks here) and pin a self-consistent mesa version.
      environment = {
        LD_LIBRARY_PATH = lib.concatStringsSep ":" [
          "${pkgs.libglvnd}/lib"
          "/run/opengl-driver/lib"
          "${pkgs.mesa}/lib"
        ];
        LIBGL_DRIVERS_PATH = lib.concatStringsSep ":" [
          "/run/opengl-driver/lib/dri"
          "${pkgs.mesa}/lib/dri"
        ];
        __EGL_VENDOR_LIBRARY_FILENAMES = "${pkgs.mesa}/share/glvnd/egl_vendor.d/50_mesa.json";
      };
    };
  };
}
