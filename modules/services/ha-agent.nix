# jupiter.* wiring for the ha-linux-agent flake (belikh/ha-linux-agent),
# which provides the actual `services.ha-linux-agent` NixOS module. Points it
# at ganymede's Mosquitto broker (modules/services/mqtt.nix) using the shared
# mqtt_ha_linux_agent sops secret — same credential the broker-side
# `ha-linux-agent` MQTT user is given in hosts/ganymede/configuration.nix.
{
  config,
  lib,
  ...
}:

let
  cfg = config.jupiter.services.haAgent;
  site = import ../../lib/site.nix;
in
{
  options.jupiter.services.haAgent = {
    enable = lib.mkEnableOption "ha-linux-agent, the Home Assistant companion daemon";

    mqttHost = lib.mkOption {
      type = lib.types.str;
      default = "ganymede.${site.domain}";
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
          };
        }
      );
      default = [ ];
      description = ''
        Remote-controllable systemd units, exposed as HA switches via
        ha-linux-agent's `backend-launcher` (see its ROADMAP.md "Layer 1 —
        session switch"). See `modules/desktop/dashboard-gaming.nix` for the
        canonical consumer (kiosk/gaming VT switch on the TCx Wave units).
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

    services.ha-linux-agent = {
      enable = true;
      settings = {
        device.id = config.networking.hostName;
        mqtt = {
          host = cfg.mqttHost;
          username = "ha-linux-agent";
          password_file = config.sops.secrets.mqtt_ha_linux_agent.path;
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
        ) cfg.launcherApps;
      };
    };
  };
}
