# Mosquitto MQTT broker — the message bus for Home Assistant and the fleet.
#
# Runs on the always-on compute node (lenovo, 10.1.1.20). Home Assistant and
# the dashboard units publish/subscribe here; see jupiter.dashboardGaming's
# Home Assistant control surface for one consumer.
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;
let
  cfg = config.jupiter.services.mqtt;
in
{
  options.jupiter.services.mqtt = {
    enable = mkEnableOption "Mosquitto MQTT broker";

    port = mkOption {
      type = types.port;
      default = 1883;
      description = "TCP port the broker listens on.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open the broker port in the firewall (intended for the trusted LAN).";
    };

    allowAnonymous = mkOption {
      type = types.bool;
      default = cfg.users == { };
      defaultText = literalExpression "true when no `users` are defined";
      description = ''
        Allow unauthenticated clients. Defaults to true only while no users are
        defined, for quick bring-up on a trusted VLAN. Define `users` (with sops
        password files) to require authentication.
      '';
    };

    users = mkOption {
      default = { };
      description = "MQTT users. Each `passwordFile` holds the plaintext password (e.g. a sops secret).";
      example = literalExpression ''
        {
          homeassistant.passwordFile = config.sops.secrets.mqtt_homeassistant.path;
          dashboard.passwordFile = config.sops.secrets.mqtt_dashboard.path;
        }
      '';
      type = types.attrsOf (
        types.submodule {
          options.passwordFile = mkOption {
            type = types.path;
            description = "File containing the user's plaintext password.";
          };
        }
      );
    };
  };

  config = mkIf cfg.enable {
    services.mosquitto = {
      enable = true;
      listeners = [
        {
          port = cfg.port;
          settings.allow_anonymous = cfg.allowAnonymous;
          # Only skip the password-file requirement when there are no users.
          omitPasswordAuth = cfg.users == { };
          users = mapAttrs (_: u: { inherit (u) passwordFile; }) cfg.users;
        }
      ];
    };

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];
  };
}
