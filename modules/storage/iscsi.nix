{ config, lib, ... }:

with lib;
let
  cfg = config.jupiter.nas.iscsi;

  # Build one LIO storage object (block backstore) per LUN.
  storageObjects = imap0 (i: lun: {
    name = lun.name;
    plugin = "block";
    dev = lun.dev;
    # Stable per-LUN WWN derived from the name (must be constant across rebuilds).
    wwn = "naa.6001405" + substring 0 9 (builtins.hashString "sha256" lun.name);
    write_back = true;
    attributes.emulate_tpu = 1; # honour UNMAP/TRIM from the initiator
  }) cfg.luns;

  luns = imap0 (i: lun: {
    index = i;
    storage_object = "/backstores/block/${lun.name}";
  }) cfg.luns;

  nodeAcls = imap0 (i: lun: {
    node_wwn = lun.initiatorIqn;
    mapped_luns = [
      {
        index = i;
        tpg_lun = i;
        write_protect = false;
      }
    ];
  }) cfg.luns;
in
{
  options.jupiter.nas.iscsi = {
    enable = mkEnableOption "LIO iSCSI target exporting zvols to network hosts";

    targetIqn = mkOption {
      type = types.str;
      default = "iqn.2026-06.au.jupiter:europa.target0";
      description = "The NAS's iSCSI target IQN.";
    };

    luns = mkOption {
      description = "Block LUNs to export. Each maps a zvol to an allowed initiator.";
      default = [ ];
      type = types.listOf (
        types.submodule {
          options = {
            name = mkOption {
              type = types.str;
              description = "Backstore name (e.g. \"db\").";
            };
            dev = mkOption {
              type = types.str;
              description = "Backing device, e.g. /dev/zvol/rpool/db.";
            };
            initiatorIqn = mkOption {
              type = types.str;
              description = ''
                The CONSUMING host's initiator IQN (the ACL). Read it on that
                host from /etc/iscsi/initiatorname.iscsi.
              '';
            };
          };
        }
      );
    };
  };

  config = mkIf cfg.enable {
    services.target = {
      enable = true;
      # NOTE: rtslib-fb is picky. If `systemctl status iscsi-target` shows a
      # restore error, build it once with `targetcli` on the box and copy the
      # resulting /etc/target/saveconfig.json back into this generator.
      config = {
        storage_objects = storageObjects;
        targets = [
          {
            fabric = "iscsi";
            wwn = cfg.targetIqn;
            tpgs = [
              {
                tag = 1;
                enable = true;
                attributes = {
                  authentication = 0;
                  generate_node_acls = 0;
                  cache_dynamic_acls = 0;
                  demo_mode_write_protect = 0;
                };
                inherit luns;
                node_acls = nodeAcls;
                portals = [
                  {
                    ip_address = "0.0.0.0";
                    port = 3260;
                  }
                ];
              }
            ];
          }
        ];
      };
    };

    networking.firewall.allowedTCPPorts = [ 3260 ];
  };
}
