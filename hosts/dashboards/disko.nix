{ ... }:

# Disko layout for the Toshiba dashboard kiosk OS disk.
#
# ⚠️  SCAFFOLDING — NOT YET CONFIRMED. `disko` is DESTRUCTIVE to the disk listed
#     below. The `device` is a deliberately non-existent placeholder so a stray
#     `disko` run fails loudly instead of wiping a real disk. Before a real
#     install you MUST replace it with the actual OS disk's stable by-id path:
#       ls -l /dev/disk/by-id/
#
# Kiosks are stateless appliances: a single OS pool, fully reproducible from
# this flake. Nothing irreplaceable lives here. If you later deploy several
# identical kiosks, they share this one nixosConfiguration and differ only by
# DHCP-assigned address.
{
  disko.devices = {
    disk.os = {
      type = "disk";
      device = "/dev/disk/by-id/REPLACE-ME-dashboard-os-disk";
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
      };
    };
  };
}
