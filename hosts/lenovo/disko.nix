{ ... }:

# Disko layout for the Lenovo compute node OS disk.
#
# ⚠️  SCAFFOLDING — NOT YET CONFIRMED. `disko` is DESTRUCTIVE to the disk listed
#     below. The `device` is a deliberately non-existent placeholder so a stray
#     `disko` run fails loudly instead of wiping a real disk. Before a real
#     install you MUST replace it with the actual OS disk's stable by-id path:
#       ls -l /dev/disk/by-id/   # pick the OS SSD/NVMe, NOT a data disk
#
# Single OS pool, no redundancy: the OS is reproducible from this flake. The
# only persistent state here (n8n, libvirt images) lives under /var and is
# covered by restic offsite (see jupiter.backups.paths in configuration.nix).
{
  disko.devices = {
    disk.os = {
      type = "disk";
      device = "/dev/disk/by-id/REPLACE-ME-lenovo-os-disk";
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
        # n8n state + libvirt VM images live here (backed up via restic).
        "var" = {
          type = "zfs_fs";
          mountpoint = "/var";
          options.mountpoint = "legacy";
        };
      };
    };
  };
}
