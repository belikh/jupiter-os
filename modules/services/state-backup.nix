{
  config,
  lib,
  pkgs,
  ...
}:

# Periodic logical backup of a host's local service state into a spool directory
# that lives on central, already-backed-up storage (e.g. an NFS mount of the
# NAS's tank/backups). This is how diskless/iSCSI hosts get covered: their data
# sits on raw zvols (block) that restic can't walk, so instead we land a
# restic-friendly logical copy on the NAS, where sanoid + restic carry it to
# snapshots + offsite with no extra wiring.
#
#   - postgres   → hourly pg_dumpall (transactionally consistent, restorable)
#   - rsyncPaths → mirrored (rsync --delete) into the spool

let
  cfg = config.jupiter.services.stateBackup;
  pgPackage = config.services.postgresql.package;
in
{
  options.jupiter.services.stateBackup = {
    enable = lib.mkEnableOption "periodic logical backup of local service state to a spool directory";

    spoolDir = lib.mkOption {
      type = lib.types.path;
      description = "Directory to write backups into. MUST be on central, backed-up storage (e.g. an NFS mount of the NAS).";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = "systemd OnCalendar interval.";
    };

    keep = lib.mkOption {
      type = lib.types.int;
      default = 24;
      description = "How many timestamped postgres dumps to retain in the spool.";
    };

    postgres = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Include an hourly pg_dumpall of the local PostgreSQL.";
    };

    rsyncPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "/var/lib/loki" ];
      description = "Directories to mirror (rsync --delete) into the spool.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.jupiter-state-backup = {
      description = "Back up local service state to ${cfg.spoolDir}";
      after = [
        "network-online.target"
        "postgresql.service"
      ];
      wants = [ "network-online.target" ];
      unitConfig.RequiresMountsFor = [ cfg.spoolDir ];
      serviceConfig.Type = "oneshot";
      path = [
        pgPackage
        pkgs.gzip
        pkgs.rsync
        pkgs.coreutils
        pkgs.util-linux # runuser
        pkgs.findutils
      ];
      script = ''
        set -euo pipefail

        ${lib.optionalString cfg.postgres ''
          mkdir -p "${cfg.spoolDir}/postgres"
          stamp="$(date +%Y%m%d-%H%M%S)"
          # pg_dumpall via local peer auth as the postgres superuser.
          runuser -u postgres -- pg_dumpall | gzip > "${cfg.spoolDir}/postgres/all-$stamp.sql.gz.partial"
          mv "${cfg.spoolDir}/postgres/all-$stamp.sql.gz.partial" "${cfg.spoolDir}/postgres/all-$stamp.sql.gz"
          # Keep only the most recent ${toString cfg.keep} dumps.
          ls -1t "${cfg.spoolDir}/postgres"/all-*.sql.gz | tail -n +${toString (cfg.keep + 1)} | xargs -r rm -f
        ''}

        ${lib.concatMapStringsSep "\n" (
          p:
          let
            name = lib.last (lib.splitString "/" p);
          in
          ''
            mkdir -p "${cfg.spoolDir}/${name}"
            rsync -a --delete "${p}/" "${cfg.spoolDir}/${name}/"
          ''
        ) cfg.rsyncPaths}
      '';
    };

    systemd.timers.jupiter-state-backup = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.interval;
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };
  };
}
