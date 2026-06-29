{
  config,
  lib,
  pkgs,
  ...
}:

# PostgreSQL server. On elitedesk its data directory lives on the iSCSI "db" LUN
# exported by the NAS, so it survives the diskless node's reboots.
#
# The specific databases/roles are intentionally NOT declared here — they belong
# with whatever consumer app lands (e.g. a Grafana for the Loki logs). Declare
# them via services.postgresql.ensureDatabases / ensureUsers in that app's module
# when it exists.

let
  cfg = config.jupiter.services.postgresql;
in
{
  options.jupiter.services.postgresql = {
    enable = lib.mkEnableOption "PostgreSQL server";

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/postgresql";
      description = "Data directory root (a versioned subdir is created beneath it).";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.postgresql_16;
      defaultText = "pkgs.postgresql_16";
      description = "PostgreSQL package/version.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.postgresql = {
      enable = true;
      package = cfg.package;
      dataDir = "${cfg.dataDir}/${cfg.package.psqlSchema}";
      # Local consumers only; no network listener until an app needs it.
      enableTCPIP = false;
    };

    # Don't start the DB until its (iSCSI-backed) data directory is mounted.
    systemd.services.postgresql.unitConfig.RequiresMountsFor = [ cfg.dataDir ];
  };
}
