{
  config,
  lib,
  ...
}:

# S.M.A.R.T. health monitoring for a host's physical disks (smartd from
# smartmontools). Watches for pre-failure SMART attributes (reallocated
# sectors, pending sectors, etc.) that predict drive failure.
#
# Alerting: failures surface as `wall` broadcasts + LOG_CRIT syslog/journal
# entries. Wire into real paging (e.g. n8n webhook) once a notification
# channel exists.

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
      autodetect = true;
      extraOptions = [
        "-i"
        (toString cfg.checkInterval)
      ];
      defaults.monitored = "-a ${cfg.selfTestSchedule}";
    };
  };
}
