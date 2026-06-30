{ ... }:

# Disko layout for the NAS *OS disk only* — the 500GB Crucial MX500 SSD (sda).
#
# ⚠️  WARNING: `disko` is DESTRUCTIVE to the disk listed here. It is deliberately
#     scoped to the OS SSD ONLY. The data pools `tank` (18TB mirror) and
#     `backup` (10TB mirror) are created BY HAND during the europa migration
#     (see scratchpad/nas-migration.md) and are merely *imported* by NixOS via
#     `boot.zfs.extraPools` in modules/zfs-nas.nix. Do NOT add them here.
#
# Before a real install, confirm the by-id path:
#   ls -l /dev/disk/by-id/ | grep -i 1921E206022D
{
  disko.devices = {
    disk.os = {
      type = "disk";
      # CONFIRM this matches the MX500 (serial 1921E206022D) before installing.
      device = "/dev/disk/by-id/ata-CT500MX500SSD1_1921E206022D";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };
          zfs = {
            size = "100%";
            content = {
              type = "zfs";
              pool = "rpool";
            };
          };
        };
      };
    };

    # Single-disk OS pool. No redundancy needed — the OS is reproducible from
    # this flake; only tank/backup hold irreplaceable data.
    zpool.rpool = {
      type = "zpool";
      rootFsOptions = {
        compression = "lz4";
        acltype = "posixacl";
        xattr = "sa";
        "com.sun:auto-snapshot" = "false";
      };
      datasets = {
        "root" = {
          type = "zfs_fs";
          mountpoint = "/";
          options.mountpoint = "legacy";
        };
        "nix" = {
          type = "zfs_fs";
          mountpoint = "/nix";
          options.mountpoint = "legacy";
        };
        "var" = {
          type = "zfs_fs";
          mountpoint = "/var";
          options.mountpoint = "legacy";
        };

        # ---- SSD "fast" tier: hot random-I/O workloads -----------------------
        # Not redundant (single SSD) by design — nothing irreplaceable lives
        # here. DB durability is the elitedesk's job; loki/scratch are
        # expendable/reproducible and snapshot+restic to tank.

        # Block devices exported to the diskless elitedesk over iSCSI.
        # The elitedesk runs the actual services (DB, Loki) from RAM and
        # persists to these zvols. Block semantics + single consumer = iSCSI.
        "db" = {
          type = "zfs_volume";
          size = "64G";
          options.volblocksize = "16k"; # tuned for a database
        };
        "loki" = {
          type = "zfs_volume";
          size = "100G";
          options.volblocksize = "16k";
        };

        # Diskless/netboot roots — SSD for fast boot-storm random reads.
        # Served read-only over NFS (see nas-nfs.nix).
        "netboot" = {
          type = "zfs_fs";
          mountpoint = "/srv/netboot";
          options.mountpoint = "legacy";
        };

        # NAS-local expendable scratch: restic cache, etc.
        "scratch" = {
          type = "zfs_fs";
          mountpoint = "/srv/scratch";
          options.mountpoint = "legacy";
        };
      };
    };
  };
}
