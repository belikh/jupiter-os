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
      };
    };
  };
}
