{
  config,
  pkgs,
  lib,
  ...
}:

with lib;
let
  cfg = config.jupiter.storage.zfs;
in
{

  options.jupiter.storage.zfs = {
    enable = mkEnableOption "Enable ZFS Impermanent Storage Layer";
    disk = mkOption {
      type = types.str;
      default = "/dev/nvme0n1";
      description = "The primary disk to partition with Disko.";
    };
  };

  config = mkIf cfg.enable {
    # Erase Your Darlings: Rollback root dataset to @blank snapshot on boot
    # systemd stage 1 requires a systemd service to rollback ZFS datasets
    boot.initrd.systemd.services.rollback = {
      description = "Rollback ZFS datasets to a pristine state";
      wantedBy = [
        "initrd.target"
      ];
      after = [
        "zfs-import-rpool.service"
      ];
      before = [
        "sysroot.mount"
      ];
      path = with pkgs; [
        zfs
      ];
      unitConfig.DefaultDependencies = "no";
      serviceConfig.Type = "oneshot";
      script = ''
        zfs rollback -r rpool/local/root@blank
      '';
    };

    # Disko configuration for ZFS impermanence
    disko.devices = {
      disk = {
        main = {
          type = "disk";
          device = cfg.disk;
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
      };
      zpool = {
        rpool = {
          type = "zpool";
          rootFsOptions = {
            compression = "lz4";
            "com.sun:auto-snapshot" = "false";
          };
          datasets = {
            "local/root" = {
              type = "zfs_fs";
              mountpoint = "/";
              options.mountpoint = "legacy";
              postCreateHook = "zfs snapshot rpool/local/root@blank";
            };
            "local/nix" = {
              type = "zfs_fs";
              mountpoint = "/nix";
              options.mountpoint = "legacy";
            };
            "safe/persist" = {
              type = "zfs_fs";
              mountpoint = "/persist";
              options.mountpoint = "legacy";
            };
          };
        };
      };
    };

    fileSystems."/persist".neededForBoot = true;
  };
}
