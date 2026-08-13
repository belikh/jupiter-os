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

  # Derived from zvolDataset rather than hardcoded, so moving the backing
  # store between pools doesn't leave this module ordering itself against —
  # or worse, `requires`-ing — a pool it no longer touches. It used to hang
  # off tank's units unconditionally; with the zvol on rpool that would have
  # made callisto's ROOT unbootable whenever tank was degraded, for no reason.
  datasetParts = lib.splitString "/" cfg.zvolDataset;
  poolName = lib.head datasetParts;
  parentDataset = lib.concatStringsSep "/" (lib.init datasetParts);
in
{
  options.jupiter.services.iscsiTarget = {
    enable = lib.mkEnableOption "a declarative LIO iSCSI target exporting one zvol as one LUN to one initiator";

    zvolDataset = lib.mkOption {
      type = lib.types.str;
      # rpool (the MX500 SSD), NOT tank. tank is a single mirror of two 18TB
      # SPINNERS with no SLOG, so with sync=standard every fsync from the
      # initiator committed to the ZIL on rust and again to the pool at txg —
      # seek-bound, at the write IOPS of one 7200rpm drive. Fine for the NAS's
      # streaming workload; not fine for a machine's ROOT filesystem. A
      # `nixos-rebuild` on callisto (Nix fsyncs on essentially every store-path
      # registration) drove single-command latency past the initiator's 30s sd
      # timeout, producing `ABORT_TASK` on europa, an I/O error on callisto's
      # root, and a hung host. Confirmed live 2026-08-13 15:03. Migrated to the
      # SSD pool the same day (tank/services/callisto-root@migrate-20260813 is
      # retained as the rollback).
      default = "rpool/services/callisto-root";
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

    primarycache = lib.mkOption {
      type = lib.types.enum [
        "all"
        "metadata"
        "none"
      ];
      default = "metadata";
      description = ''
        ARC caching policy for the backing zvol. "metadata" by default, NOT
        "all": the initiator has its own page cache and is caching this
        filesystem already, so caching its data blocks a second time on the
        target buys little and costs the target's RAM — which here is 7.7GiB
        shared with Samba/NFS, Harmonia, headscale+DERP and the ROM pipeline,
        on a box that has OOM-killed its own iSCSI receive thread. callisto
        has 64GB to europa's 7.7GiB, so the duplicate copy is on exactly the
        wrong machine. Metadata stays cached because a metadata miss is a
        seek, not a read.
      '';
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
    # Ordering: after this zvol's OWN pool import, derived from zvolDataset.
    # The previous shape hardcoded tank's units and additionally
    # `requires`-ed zfs-create-tank-datasets.service (the oneshot in
    # modules/storage/zfs-nas.nix that made the "tank/services" parent),
    # because the parent had to exist before `zfs create -V` and two siblings
    # off the same predecessor otherwise race — `zfs create -V …` fails
    # outright ("parent does not exist") if this one wins. That coupling is
    # gone: the parent is created here with `zfs create -p`, so this unit is
    # self-sufficient on whichever pool the zvol lives on. Ordering against a
    # unit that doesn't exist is a systemd no-op, so the pool-specific name is
    # safe even for a root pool imported in the initrd.
    #
    # `wantedBy` alone only pulls this unit in when iscsi-target.service is
    # requested — it doesn't make that unit WAIT on this one succeeding, so a
    # failed zvol-creation would leave iscsi-target.service to start anyway
    # and fail on its own (referencing a backstore device that was never
    # created), with nothing surfacing why. iscsi-target's own `requires`
    # below closes that gap.
    systemd.services.zfs-create-iscsi-zvol = {
      description = "Create the ${cfg.zvolDataset} zvol backing the iSCSI target (idempotent)";
      after = [
        "zfs-import.target"
        "zfs-import-${poolName}.service"
      ];
      before = [ "iscsi-target.service" ];
      wantedBy = [ "iscsi-target.service" ];
      path = [ pkgs.zfs ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        if ! zfs list -H -o name "${parentDataset}" >/dev/null 2>&1; then
          echo "Creating parent dataset ${parentDataset}"
          zfs create -p "${parentDataset}"
        fi
        if ! zfs list -H -o name "${cfg.zvolDataset}" >/dev/null 2>&1; then
          echo "Creating zvol ${cfg.zvolDataset} (${cfg.zvolSize})"
          zfs create -V "${cfg.zvolSize}" -o volblocksize=16K \
            -o primarycache="${cfg.primarycache}" "${cfg.zvolDataset}"
        fi
        # Enforce on every start, not only at creation: the zvol usually
        # already exists (it survives reinstalls, and this one was migrated in
        # by `zfs send`), so a create-time-only property would silently never
        # apply to the volume actually in use. `zfs set` is idempotent.
        zfs set primarycache="${cfg.primarycache}" "${cfg.zvolDataset}"
      '';
    };

    systemd.services.iscsi-target = {
      requires = [ "zfs-create-iscsi-zvol.service" ];
      after = [ "zfs-create-iscsi-zvol.service" ];

      # Assert the LUN actually got exported. `targetctl restore` treats every
      # per-object failure as a WARNING and still exits 0, so the unit reports
      # `active` while exporting a target with nothing behind it. Observed live
      # 2026-08-13 after a stop/start where the backstore device was still held:
      #
      #   targetctl: Could not create StorageObject callisto-root: Cannot
      #     configure StorageObject because device {dev} is already in use, skipped
      #   targetctl: Could not find matching StorageObject for LUN 0, skipped
      #   targetctl: Could not find matching TPG LUN 0 for MappedLUN 0, skipped
      #   systemd[1]: Finished iscsi-target.service.
      #
      # The initiator then LOGS IN FINE — the ACL and portal restored, so a TCP
      # session establishes — and simply finds no block device, which surfaces
      # on the far side as an unexplained stage-1 "cannot find root" on a host
      # whose root this is. `systemctl is-active` is worthless here; only the
      # configfs tree tells the truth. Checked there rather than by parsing
      # targetcli, so this needs no extra runtime dependency.
      #
      # On failure systemd marks the unit failed and runs ExecStop
      # (targetctl clear). That leaves the target down rather than half-up:
      # the same practical outcome, but a LOUD one that `systemctl status`
      # and a failed-units check will surface instead of hiding.
      serviceConfig.ExecStartPost = [
        (toString (
          pkgs.writeShellScript "assert-iscsi-lun-exported" ''
            tpg="/sys/kernel/config/target/iscsi/${cfg.targetIqn}/tpgt_1"
            if [ ! -d "$tpg/lun/lun_0" ]; then
              echo "iscsi-target: TPG LUN 0 is MISSING under $tpg/lun — the target is exporting nothing." >&2
              echo "iscsi-target: check 'journalctl -u iscsi-target' for skipped-object warnings from targetctl restore." >&2
              exit 1
            fi
            if [ ! -d "$tpg/acls/${cfg.initiatorIqn}/lun_0" ]; then
              echo "iscsi-target: MappedLUN 0 is MISSING for ${cfg.initiatorIqn} — it can log in but will see no disk." >&2
              exit 1
            fi
            echo "iscsi-target: verified LUN 0 exported and mapped to ${cfg.initiatorIqn}"
          ''
        ))
      ];
    };

    networking.firewall.allowedTCPPorts = [ cfg.portalPort ];
  };
}
