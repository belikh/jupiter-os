{ config, lib, ... }:

# Per-host declaration of "this host holds persistent state that must reach the
# central data store (the NAS) and thence offsite". This is the automatic wiring
# point: set jupiter.backup (or let the storage profile default it on for
# servers) and the NAS picks the host up on its own — the replication sources are
# DERIVED from every host's jupiter.backup in flake.nix (see backupHubModule), so
# you never edit the NAS when adding a host.
#
# What this module does on the source side: authorize the hub's syncoid key to
# pull as root (restricted to the hub's address). root already has full zfs
# privileges, so no `zfs allow` is needed. The NAS side (the actual syncoid
# commands) is generated in flake.nix.

let
  cfg = config.jupiter.backup;
  site = import ../../lib/site.nix;
in
{
  options.jupiter.backup = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Replicate this host's persistent state to the central data store (NAS).
        The `stateful` storage profile defaults this on; appliances/workstations
        (impermanent/minimal, or hosts whose data already lives on the NAS over
        iSCSI) leave it off.
      '';
    };

    datasets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "rpool/var" ];
      description = ''
        ZFS datasets on this host to replicate to the hub. Defaulted by the
        storage profile (stateful → [ "rpool/var" ]); extend or override here.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.datasets != [ ];
        message = "jupiter.backup.enable is set on host '${config.networking.hostName}' but jupiter.backup.datasets is empty — nothing would be replicated to the NAS.";
      }
    ];

    # Let the hub pull as root, but only from the hub's address.
    users.users.root.openssh.authorizedKeys.keys = [
      ''from="${site.backupHub.address}" ${site.backupHub.syncoidPublicKey}''
    ];
  };
}
