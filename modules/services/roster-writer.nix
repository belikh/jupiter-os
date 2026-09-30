# roster-writer — the ISS/Kronos roster sole-writer (spec §8.1/§8.2).
#
# Takes over n8n's "Roster to Home Assistant" + "Shift Change Watchdog":
# a bounded-interval poller (pkgs/roster-writer, n8n-parity parser — see
# PKGS/roster-writer/PARITY.md) that writes the canonical roster tables in
# the fleet Postgres and publishes the retained MQTT contract HA consumes
# (jupiter/schedule/shift/* + discovery for sensor.next_shift_roster).
#
# Secrets: roster_ical_url, pg_roster_password, mqtt_roster_password — all
# sops files read by the ExecStart wrapper into the process environment.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.jupiter.services.rosterWriter;

  inherit (import ../lib.nix { inherit config lib pkgs; }) commonServiceHardening;

  pkg = pkgs.callPackage ../../pkgs/roster-writer { };
in
{
  options.jupiter.services.rosterWriter = {
    enable = lib.mkEnableOption "Kronos roster sole-writer (Postgres custody + MQTT contract)";

    interval = lib.mkOption {
      type = lib.types.str;
      default = "15m";
      description = "Poll interval (Go duration; e.g. 15m).";
    };

    objectId = lib.mkOption {
      type = lib.types.str;
      default = "next_shift_roster";
      description = ''
        HA discovery object_id. The dual-run default keeps the MQTT sensor
        distinct from n8n's REST-pushed ghost (`next_shift`); the atomic flip
        republishes discovery with `next_shift` so the registry takes the
        canonical entity id.
      '';
    };

    mqttHost = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "MQTT broker host.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.pg_roster_password = { };
    sops.secrets.roster_ical_url = { };
    sops.secrets.mqtt_roster_password = { };

    systemd.services.jupiter-roster-writer = {
      description = "Kronos roster sole-writer → fleet Postgres + MQTT contract";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "postgresql.service"
        "mosquitto.service"
      ];
      wants = [ "network-online.target" ];

      environment = {
        ROSTER_INTERVAL = cfg.interval;
        ROSTER_OBJECT_ID = cfg.objectId;
      };

      serviceConfig = {
        Type = "exec";
        # Secrets never touch the store or the unit file: the wrapper reads
        # the sops files at start and composes the URLs in-process.
        ExecStart = pkgs.writeShellScript "roster-writer-start" ''
          export ROSTER_ICAL_URL="$(cat ${config.sops.secrets.roster_ical_url.path})"
          pgpw="$(cat ${config.sops.secrets.pg_roster_password.path})"
          export ROSTER_DATABASE_URL="postgresql://roster:''${pgpw}@127.0.0.1:5432/jupiter?sslmode=disable"
          mqtt="$(cat ${config.sops.secrets.mqtt_roster_password.path})"
          export ROSTER_MQTT_URL="mqtt://roster-writer:''${mqtt}@${cfg.mqttHost}:1883"
          exec ${lib.getExe pkg}
        '';
        Restart = "on-failure";
        RestartSec = "30s";

        # Network (Kronos + Postgres + broker) and read access to sops
        # secrets; the daemon is stateless apart from Postgres.
        ReadOnlyPaths = [ "/run/secrets" ];
      }
      // commonServiceHardening;
    };
  };
}
