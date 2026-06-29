{ config, lib, ... }:

# Pull-based ZFS replication (syncoid) onto this host. The NAS is the data hub:
# servers' state datasets are pulled here on a timer, and only the NAS holds the
# offsite (restic) egress — so no other host backs up directly offsite.
#
# Provisioning (one-time, per source host):
#   1. On this (puller) host, generate the syncoid keypair and store the private
#      key as the `syncoid_ssh_key` sops secret referenced by sshKeyPath.
#   2. Authorize the matching PUBLIC key for root on each source host
#      (users.users.root.openssh.authorizedKeys.keys).
#   3. Grant send rights on the source dataset, e.g. on the source:
#        zfs allow -u root send,snapshot,hold rpool/var
#      (root already has them; a dedicated user would need this explicitly.)

let
  cfg = config.jupiter.replication;
in
{
  options.jupiter.replication = {
    enable = lib.mkEnableOption "pull-based ZFS replication (syncoid) onto this host";

    sshKeyPath = lib.mkOption {
      type = lib.types.path;
      description = ''
        Private SSH key syncoid uses to pull from each remote (typically a sops
        secret path). The matching public key must be authorized on every source
        host with permission to `zfs send` the source dataset.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = "systemd OnCalendar interval for the replication timers.";
    };

    sources = lib.mkOption {
      default = { };
      description = "Datasets to pull onto this host, keyed by an arbitrary name.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            remote = lib.mkOption {
              type = lib.types.str;
              example = "root@lenovo.home.jupiter.au";
              description = "user@host of the source machine.";
            };
            sourceDataset = lib.mkOption {
              type = lib.types.str;
              example = "rpool/var";
            };
            targetDataset = lib.mkOption {
              type = lib.types.str;
              example = "tank/backups/lenovo";
            };
          };
        }
      );
    };
  };

  config = lib.mkIf cfg.enable {
    services.syncoid = {
      enable = true;
      interval = cfg.interval;
      sshKey = cfg.sshKeyPath;
      # syncoid takes its own pre-send snapshot, so the source doesn't need a
      # snapshot policy of its own for replication to work.
      commands = lib.mapAttrs (_: s: {
        source = "${s.remote}:${s.sourceDataset}";
        target = s.targetDataset;
        recursive = true;
      }) cfg.sources;
    };
  };
}
