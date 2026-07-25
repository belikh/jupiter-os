# jupiter.* wiring for the ha-linux-agent flake (belikh/ha-linux-agent)
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

    mqttHost = lib.mkOption {
      type = lib.types.str;
      default = "localhost";
      description = "Mosquitto broker to publish sensors/commands to.";
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
                Set to expose this profile as a dimmable HA `light` (JSON
                schema, brightness + on/off) instead of a plain `switch`.
                On/off still goes through this profile's `unit`
                (start/stop); brightness reads/writes
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
        `backend-launcher` (see its ROADMAP.md "Layer 1 — session switch"
        for the design). Profiles sharing a `group` collapse into one HA
        `select` instead of independent switches.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Owned by io (not root) since the agent runs as a systemd --user service.
    sops.secrets.mqtt_ha_linux_agent.owner = "io";

    # ha-linux-agent runs as a systemd --user service (needs io's D-Bus
    # session bus for notifications/niri sensors); enable lingering so it
    # comes up at boot rather than only after first login.
    users.users.io.linger = true;

    systemd.user.services.ha-linux-agent.unitConfig = {
      ConditionUser = "io";
    };

    systemd.services.ha-linux-agent-sysfs-perms = {
      description = "Set permissions for ha-linux-agent sysfs files";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.bash}/bin/bash -c 'chmod 0666 /sys/class/backlight/*/brightness /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference || true'";
        RemainAfterExit = true;
      };
    };

    services.ha-linux-agent = {
      enable = true;
      settings = {
        device.id = config.networking.hostName;
        mqtt = {
          host = cfg.mqttHost;
          username = "ha-linux-agent";
          password_file = config.sops.secrets.mqtt_ha_linux_agent.path;
        };
        backends.hardware = {
          enable = true;
          cpu_governor = true;
          cpu_epp = true;
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
