{
  config,
  lib,
  ...
}:

# S.M.A.R.T. health monitoring for a host's physical disks (smartd from
# smartmontools). Closes the "no disk/hardware health monitoring" gap noted
# in docs/roadmap.md — europa's tank/backup mirrors are only redundant against
# a drive *failure*; nothing previously watched for the pre-failure SMART
# attributes (reallocated sectors, pending sectors, etc.) that usually predict
# one.
#
# Alerting here is intentionally minimal: the fleet has no metrics/paging
# stack yet (see docs/roadmap.md "Operational maturity gaps"), so failures
# surface as `wall` broadcasts plus a LOG_CRIT syslog/journal entry smartd
# always emits on a failed check — visible via `journalctl -u smartd`. Wire
# this into real paging once a notification channel (e.g. an n8n webhook)
# exists.

let
  cfg = config.jupiter.storage.smartMonitoring;
in
{
  options.jupiter.storage.smartMonitoring = {
    enable = lib.mkEnableOption "S.M.A.R.T. self-tests and health checks on all attached disks";

    checkInterval = lib.mkOption {
      type = lib.types.int;
      default = 1800;
      description = "Seconds between smartd health checks.";
    };

    selfTestSchedule = lib.mkOption {
      type = lib.types.str;
      default = "-s (S/../.././02|L/../../7/03)";
      description = ''
        smartd `-s` schedule: short self-test daily at 02:00, long self-test
        weekly on Sundays at 03:00. Passed straight through to smartd.conf.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.smartd = {
      enable = true;
      # Disks aren't enumerated in the flake (tank/backup are hand-created,
      # see hosts/europa/disko.nix) — scan everything smartd finds instead of
      # hardcoding by-id paths that would drift from real hardware.
      autodetect = true;
      defaults.autodetected = "-a -o on ${cfg.selfTestSchedule}";
      extraOptions = [ "--interval=${toString cfg.checkInterval}" ];
      notifications.wall.enable = true;
    };
  };
}
