# Mosquitto MQTT broker — the message bus for Home Assistant and the fleet.
#
# Runs on the always-on compute node (ganymede, 10.1.1.20). Home Assistant and
# the dashboard units publish/subscribe here; see jupiter.dashboardGaming's
# Home Assistant control surface for one consumer.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.jupiter.services.mqtt;
in
{
  options.jupiter.services.mqtt = {
    enable = lib.mkEnableOption "Mosquitto MQTT broker";

    port = lib.mkOption {
      type = lib.types.port;
      default = 1883;
      description = "TCP port the broker listens on.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the broker port in the firewall (intended for the trusted LAN).";
    };

    allowAnonymous = lib.mkOption {
      type = lib.types.bool;
      default = cfg.users == { };
      defaultText = lib.literalExpression "true when no `users` are defined";
      description = ''
        Allow unauthenticated clients. Defaults to true only while no users are
        defined, for quick bring-up on a trusted VLAN. Define `users` (with sops
        password files) to require authentication.
      '';
    };

    users = lib.mkOption {
      default = { };
      description = ''
        MQTT users. Each `passwordFile` holds the plaintext password (e.g. a
        sops secret). `acl` grants topic access — mosquitto's acl-file
        plugin (which the underlying `services.mosquitto` module always
        loads) default-denies any topic with no matching rule, so a user
        with an empty `acl` can authenticate but can't publish or subscribe
        to anything. Always set `acl` for a user that needs to do anything.
      '';
      example = lib.literalExpression ''
        {
          homeassistant = {
            passwordFile = config.sops.secrets.mqtt_homeassistant.path;
            acl = [ "readwrite #" ];
          };
          ha-linux-agent = {
            passwordFile = config.sops.secrets.mqtt_ha_linux_agent.path;
            acl = [
              "readwrite homeassistant/#"
              "readwrite ha-linux-agent/#"
            ];
          };
        }
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            passwordFile = lib.mkOption {
              type = lib.types.path;
              description = "File containing the user's plaintext password.";
            };
            acl = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = ''
                Topic ACL entries, each `"[read|write|readwrite] <topic pattern>"`
                (mosquitto acl-file syntax — see `man mosquitto.conf`). Required:
                an authenticated user with no `acl` entries is denied every
                topic, not granted full access.
              '';
            };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = lib.mapAttrsToList (name: u: {
      assertion = cfg.allowAnonymous || u.acl != [ ];
      message = ''
        jupiter.services.mqtt.users.${name} has no `acl` entries. mosquitto's
        acl-file plugin default-denies every topic for an authenticated user
        with an empty ACL — this user would connect successfully but be
        unable to publish or subscribe to anything. Set `acl`, e.g.
        [ "readwrite #" ].
      '';
    }) cfg.users;

    services.mosquitto = {
      enable = true;
      listeners = [
        {
          port = cfg.port;
          settings.allow_anonymous = cfg.allowAnonymous;
          # Only skip the password-file requirement when there are no users.
          omitPasswordAuth = cfg.users == { };
          users = lib.mapAttrs (_: u: { inherit (u) passwordFile acl; }) cfg.users;
        }
      ];
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
