# jupiter.* wiring for the ha-linux-agent flake (belikh/ha-linux-agent)
#
# Fleet service model (2026-09 reliability rework): ONE system service per
# host, role-switched — the systemd --user shape is retired. A system
# service restarts cleanly on every `nixos-rebuild switch` and orders
# against network-online.target; a user unit can do neither, and since
# nixpkgs PR #517768 (May 2026) switch-to-configuration runs a disruptive
# per-user restart pass for any live user manager — exactly the wrong shape
# for an appliance fleet.
#
# The launcher's system-scope polkit grants (subject.user == "io") survive
# unchanged: a User=io system service satisfies the same match.
#
# The old ha-linux-agent-sysfs-perms chmod oneshot is DELETED: it granted
# group-root writes the agent user could never use (io's only group was
# wheel), so brightness writes failed EACCES silently. The kiosk role now
# ships the upstream module's udev rule (video group gets write on
# brightness — never bl_power, which cuts a rail the TCxWave touch
# digitiser shares) plus io-in-video membership.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.jupiter.services.haAgent;
in
{
  options.jupiter.services.haAgent = {
    enable = lib.mkEnableOption "ha-linux-agent, the Home Assistant companion daemon";

    role = lib.mkOption {
      type = lib.types.enum [
        "kiosk"
        "server"
        "minimal"
      ];
      default = "minimal";
      description = ''
        Host class, forwarded to the upstream module's role switch:
        - kiosk: session-bus Environment block (the agent reaches
          notification/compositor sessions on a lingered user) + the udev
          video-group backlight rule + io-in-video.
        - server: headless — no session bus to reach; session-dependent
          features warn-and-disable.
        - minimal: baseline unit only.
      '';
    };

    mqttHost = lib.mkOption {
      type = lib.types.str;
      default = config.jupiter.fleet.addresses.callisto;
      description = "Mosquitto broker to publish sensors/commands to.";
    };

    pollIntervalSecs = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = ''
        Seconds between sensor polls/state publishes (applies fleet-wide to
        every sensor this agent exposes, not just launcher profiles).
        Defaults to ha-linux-agent's own default (30s) when unset.
      '';
    };

    launcherApps = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            id = lib.mkOption {
              type = lib.types.str;
              description = "Stable id — becomes the MQTT switch entity id and command-topic allowlist entry.";
            };
            name = lib.mkOption {
              type = lib.types.str;
              description = "HA-facing display name.";
            };
            unit = lib.mkOption {
              type = lib.types.str;
              description = "systemd unit this profile starts/stops.";
            };
            scope = lib.mkOption {
              type = lib.types.enum [
                "user"
                "system"
              ];
              default = "user";
              description = "`systemctl --user` vs plain `systemctl`.";
            };
            group = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Profiles sharing a group are mutually exclusive.";
            };
            icon = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Optional mdi icon override.";
            };
            backlight = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Set to expose this profile as a dimmable HA `light`
                (brightness + on/off) instead of a plain `switch`. On/off
                still goes through this profile's `unit` (start/stop);
                brightness reads/writes
                `/sys/class/backlight/<value>/brightness` directly. Empty
                string ("") auto-detects the first backlight device.
                Mutually exclusive with `group` — a dimmable screen and a
                mutually-exclusive session switch are different enough
                concerns that jupiter-os never needs both on one profile.
              '';
            };
          };
        }
      );
      default = [ ];
      description = ''
        Remote-controllable systemd units, exposed as HA switches (or, with
        `backlight` set, one dimmable light) via ha-linux-agent's
        `backend-launcher`. Profiles sharing a `group` collapse into one HA
        `select` instead of independent switches.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Owned by io (not root): the system service runs as User=io and reads
    # the password file directly.
    sops.secrets.mqtt_ha_linux_agent.owner = "io";

    # Linger stays — but for the CAGE SESSIONS (a kiosk's graphical session
    # must survive without an interactive login), not for the agent: the
    # agent is a system service now. Enable only where a session bus exists
    # to keep alive (kiosk role).
    users.users.io = {
      linger = lib.mkIf (cfg.role == "kiosk") true;
      # Backlight writes: the udev rule (shipped by the upstream module's
      # kiosk role) puts brightness nodes in the video group; io needs
      # membership to write them. Supplementary groups for a system service
      # are computed at ExecStart spawn time, so the restart that follows
      # this switch picks the membership up without a re-login.
      extraGroups = lib.mkIf (cfg.role == "kiosk") [ "video" ];
    };

    services.ha-linux-agent = {
      enable = true;
      role = cfg.role;
      settings = {
        device.id = config.networking.hostName;
        mqtt = {
          host = cfg.mqttHost;
          username = "ha-linux-agent";
          password_file = config.sops.secrets.mqtt_ha_linux_agent.path;
        }
        // lib.optionalAttrs (cfg.pollIntervalSecs != null) {
          poll_interval_secs = cfg.pollIntervalSecs;
        };
        backends.hardware = {
          enable = true;
          cpu_governor = true;
          cpu_epp = true;
          # Kiosks expose their backlight via a launcherApps `light` profile
          # (the screen-power entry below) — leaving this at its true default
          # would publish a second, independent brightness control for the
          # exact same backlight device (confirmed live on amalthea
          # 2026-07-25: io still saw a separate slider alongside the new
          # light).
          backlight = cfg.role != "kiosk";
        };
        backends.launcher.apps = map (
          app:
          {
            inherit (app)
              id
              name
              unit
              scope
              ;
          }
          // lib.optionalAttrs (app.group != null) { inherit (app) group; }
          // lib.optionalAttrs (app.icon != null) { inherit (app) icon; }
          // lib.optionalAttrs (app.backlight != null) { inherit (app) backlight; }
        ) cfg.launcherApps;
      };
    };
  };
}
