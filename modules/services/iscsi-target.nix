{
  config,
  lib,
  pkgs,
  ...
}:

# Declarative LIO iSCSI target (services.target — the kernel's LIO target,
# configured via services.target.config = the same JSON shape targetcli's
# `saveconfig` reads/writes) exporting a single ZFS zvol as a single LUN to
# a single initiator.
#
# Built for callisto's root-over-iSCSI (hosts/callisto/configuration.nix
# boots off the LUN this exports) but kept host-name-agnostic in case a
# second diskless host needs the same pattern later — every identity is a
# config.jupiter.services.iscsiTarget.* option, nothing here hardcodes
# "callisto".
#
# No CHAP: node_acls are scoped by initiator IQN only. This requires an
# EXPLICIT `attributes.authentication = 0` on the TPG below — the kernel
# target (drivers/target/iscsi/iscsi_target_nego.c) defaults every TPG's
# `authentication` attribute to 1 (required) and every NodeACL to inherit
# that, so omitting the block entirely (as a first draft of this module
# did) leaves CHAP enforced with no credentials configured anywhere —
# login fails outright, not "falls back to open". Confirmed against
# nixpkgs' own nixos/tests/iscsi-root.nix, which sets the same override for
# the same reason. The LAN this listens on (10.1.1.0/24) is already the
# trust boundary every other LUN-adjacent service here relies on (see
# modules/storage/nas-nfs.nix's IP-scoped NFS export for the same host).
#
# The zvol is created here (not modules/storage/zfs-nas.nix's
# tankDatasets list) because it's a `zfs create -V` volume, not a
# `zfs create` filesystem dataset — a different command, and one that's
# meaningless without an iSCSI target consuming it, so it stays local to
# this module instead of adding a second dataset shape to zfs-nas.nix's
# idempotent-creation script.

let
  cfg = config.jupiter.services.iscsiTarget;

  backstoreName = "callisto-root";
  zvolPath = "/dev/zvol/${cfg.zvolDataset}";
in
{
  options.jupiter.services.iscsiTarget = {
    enable = lib.mkEnableOption "a declarative LIO iSCSI target exporting one zvol as one LUN to one initiator";

    zvolDataset = lib.mkOption {
      type = lib.types.str;
      default = "tank/services/callisto-root";
      description = "ZFS zvol (block volume, not a filesystem dataset) backing the exported LUN.";
    };

    zvolSize = lib.mkOption {
      type = lib.types.str;
      default = "200G";
      description = ''
        Size of the backing zvol, in `zfs create -V` syntax. Sized for a
        Nix store + system root, not raw data — this is not a NAS dataset.
      '';
    };

    portalAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.1.1.2";
      description = "iSCSI portal (target) bind address.";
    };

    portalPort = lib.mkOption {
      type = lib.types.port;
      default = 3260;
      description = "iSCSI portal (target) port.";
    };

    targetIqn = lib.mkOption {
      type = lib.types.str;
      description = "This target's own IQN (the `wwn` of the exported iSCSI target).";
      example = "iqn.2026-07.au.jupiter:europa:callisto-root";
    };

    initiatorIqn = lib.mkOption {
      type = lib.types.str;
      description = ''
        The single initiator IQN allowed to log into this target (the
        node_acls entry). Access control is by IQN only — see the no-CHAP
        note above.
      '';
      example = "iqn.2026-07.au.jupiter:callisto";
    };
  };

  config = lib.mkIf cfg.enable {
    services.target = {
      enable = true;
      config = {
        storage_objects = [
          {
            plugin = "block";
            name = backstoreName;
            dev = zvolPath;
          }
        ];
        targets = [
          {
            wwn = cfg.targetIqn;
            fabric = "iscsi";
            tpgs = [
              {
                tag = 1;
                enable = true;
                # See the no-CHAP note above the options block: without this,
                # the kernel target's default (authentication required, no
                # credentials configured anywhere) rejects every login.
                attributes.authentication = 0;
                portals = [
                  {
                    ip_address = cfg.portalAddress;
                    port = cfg.portalPort;
                  }
                ];
                luns = [
                  {
                    index = 0;
                    storage_object = "/backstores/block/${backstoreName}";
                  }
                ];
                node_acls = [
                  {
                    node_wwn = cfg.initiatorIqn;
                    mapped_luns = [
                      {
                        index = 0;
                        tpg_lun = 0;
                        write_protect = false;
                      }
                    ];
                  }
                ];
              }
            ];
          }
        ];
      };
    };

    # Create the backing zvol idempotently at boot, before the LIO target
    # tries to attach it. Mirrors modules/storage/zfs-nas.nix's
    # idempotent-creation-script style, but for a volume (-V) instead of a
    # filesystem dataset.
    #
    # Ordering: the zvol's dataset PARENT ("tank/services", part of
    # cfg.zvolDataset's path) is created by a separate oneshot in
    # modules/storage/zfs-nas.nix (zfs-create-tank-datasets.service), which
    # — like this one — only depends on zfs-import-tank.service. Two
    # siblings hanging off the same predecessor race unless one explicitly
    # orders after the other; `zfs create -V ... tank/services/...` fails
    # outright ("parent does not exist") if this one wins that race. And
    # `wantedBy` alone only pulls this unit in when iscsi-target.service is
    # requested — it doesn't make that unit WAIT on this one succeeding, so
    # a failed zvol-creation leaves iscsi-target.service to start anyway and
    # fail on its own (referencing a backstore device that was never
    # created), with nothing surfacing why. `requires` closes that gap.
    systemd.services.zfs-create-iscsi-zvol = {
      description = "Create the ${cfg.zvolDataset} zvol backing the iSCSI target (idempotent)";
      after = [
        "zfs-import-tank.service"
        "zfs-create-tank-datasets.service"
      ];
      before = [ "iscsi-target.service" ];
      requires = [ "zfs-create-tank-datasets.service" ];
      wantedBy = [ "iscsi-target.service" ];
      path = [ pkgs.zfs ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        if ! zfs list -H -o name "${cfg.zvolDataset}" >/dev/null 2>&1; then
          echo "Creating zvol ${cfg.zvolDataset} (${cfg.zvolSize})"
          zfs create -V "${cfg.zvolSize}" -o volblocksize=16K "${cfg.zvolDataset}"
        fi
      '';
    };

    systemd.services.iscsi-target = {
      requires = [ "zfs-create-iscsi-zvol.service" ];
      after = [ "zfs-create-iscsi-zvol.service" ];
    };

    networking.firewall.allowedTCPPorts = [ cfg.portalPort ];
  };
}
