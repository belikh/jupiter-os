{
  config,
  pkgs,
  lib,
  ...
}:

# Shared ZFS-on-root disko layouts, selected per host by an opinionated
# `jupiter.storage.profile`. Hosts with bespoke multi-pool layouts (the future
# NAS) keep their own `disko.nix` and leave `profile = "none"`.
#
# Profiles:
#   impermanent  rpool/{local/root@blank, local/nix, safe/persist}; root rolls
#                back to @blank every boot (erase-your-darlings). Pair with
#                jupiter.core.impermanence to choose what survives. For
#                appliances/workstations (kiosks, laptop).
#   stateful     rpool/{root, nix, var}; persistent root, no rollback. For
#                always-on servers whose state must not be wiped on reboot.
#   minimal      rpool/{root, nix}; persistent root, no extra datasets.
#   none         contributes nothing (default) — the host declares its own
#                disko layout, or is diskless.
#
# Kernel note: any host with a ZFS root deliberately stays on the stock
# `pkgs.linuxPackages` default — always within ZFS's supported range and
# served from cache.nixos.org. The old tree's per-host kernel picks
# (linuxPackages_latest, CachyOS) are what forced the unbuildable
# lib.mkForce kernel-pinning hack here; don't reintroduce them on ZFS hosts.

let
  cfg = config.jupiter.storage;

  isImpermanent = cfg.profile == "impermanent";

  # Sane pool-wide defaults shared by every profile.
  rootFsOptions = {
    compression = "lz4";
    acltype = "posixacl";
    xattr = "sa";
    "com.sun:auto-snapshot" = "false";
  };

  mkDataset = mountpoint: {
    type = "zfs_fs";
    inherit mountpoint;
    options.mountpoint = "legacy";
  };

  datasetsByProfile = {
    impermanent = {
      "local/root" = {
        type = "zfs_fs";
        mountpoint = "/";
        options.mountpoint = "legacy";
        # The pristine snapshot the rollback service restores to each boot.
        postCreateHook = "zfs snapshot rpool/local/root@blank";
      };
      "local/nix" = mkDataset "/nix";
      "safe/persist" = mkDataset "/persist";
      # Real disk-backed swap (today: only the kiosks use "impermanent") —
      # zram alone isn't enough headroom for an occasional heavy dispatched
      # build (e.g. mypyc landed here 2026-07-20 and pushed a kiosk to
      # 168Mi free / actively swapping into zram before intervention). A
      # zvol is the ZFS-supported way to do swap — a plain swapfile on a
      # ZFS dataset risks deadlock under memory pressure. disko wires this
      # content type straight into `swapDevices` automatically. Content
      # is inherently transient, so it lives under local/ like root/nix,
      # not safe/. compression=off + sync=always + no cache: standard ZFS
      # swap-zvol tuning (swap shouldn't be compressed or cached twice).
      "local/swap" = {
        type = "zfs_volume";
        size = "8G";
        content = {
          type = "swap";
        };
        options = {
          compression = "off";
          sync = "always";
          primarycache = "metadata";
          secondarycache = "none";
        };
      };
    };
    stateful = {
      "root" = mkDataset "/";
      "nix" = mkDataset "/nix";
      "var" = mkDataset "/var";
    };
    minimal = {
      "root" = mkDataset "/";
      "nix" = mkDataset "/nix";
    };
  };
in
{
  options.jupiter.storage = {
    profile = lib.mkOption {
      type = lib.types.enum [
        "none"
        "impermanent"
        "stateful"
        "minimal"
      ];
      default = "none";
      description = ''
        Opinionated ZFS-on-root disko layout for this host. "none" leaves the
        host to declare its own layout (or be diskless). See the profile
        descriptions at the top of modules/storage/zfs-profiles.nix.
      '';
    };

    disk = lib.mkOption {
      type = lib.types.str;
      default = "/dev/disk/by-id/REPLACE-ME";
      description = ''
        The OS disk to partition. disko is DESTRUCTIVE to this device, so it
        defaults to a placeholder — set it to the real /dev/disk/by-id path
        before installing.
      '';
    };

    espSize = lib.mkOption {
      type = lib.types.str;
      default = "1G";
      description = "Size of the EFI System Partition.";
    };
  };

  config = lib.mkIf (cfg.profile != "none") {
    # A warning, not a hard assertion: a REPLACE-ME disk must not block
    # `nix build` / `nix flake check` / CI. The placeholder path doesn't exist
    # on disk, so disko itself fails loudly ("no such device") if someone
    # tries to actually install against it — this is just an earlier,
    # friendlier nudge.
    warnings = lib.optional (lib.hasInfix "REPLACE-ME" cfg.disk) ''
      jupiter.storage.disk on host "${config.networking.hostName}" is still
      the REPLACE-ME placeholder. disko will WIPE whatever device this
      points at, so set it to the real /dev/disk/by-id path of the OS disk
      before installing:
        ls -l /dev/disk/by-id/   # pick the OS SSD/NVMe, NOT a data disk
    '';

    # Erase-your-darlings: roll the root dataset back to its @blank snapshot
    # in initrd, before the root is mounted. Only meaningful for the
    # impermanent profile. Requires boot.initrd.systemd.enable.
    boot.initrd.systemd.services.rollback = lib.mkIf isImpermanent {
      description = "Rollback root ZFS dataset to a pristine state";
      wantedBy = [ "initrd.target" ];
      after = [ "zfs-import-rpool.service" ];
      before = [ "sysroot.mount" ];
      path = [ pkgs.zfs ];
      unitConfig.DefaultDependencies = "no";
      serviceConfig.Type = "oneshot";
      # Guard on the snapshot existing: a no-op if the pool isn't present
      # (e.g. a synthesized build-vm during CI), and we'd rather skip than
      # wedge boot if the @blank snapshot is somehow missing on real hardware.
      script = ''
        if zfs list -t snapshot rpool/local/root@blank >/dev/null 2>&1; then
          zfs rollback -r rpool/local/root@blank
        fi
      '';
    };

    disko.devices = {
      disk.main = {
        type = "disk";
        device = cfg.disk;
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = cfg.espSize;
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
        inherit rootFsOptions;
        datasets = datasetsByProfile.${cfg.profile};
      };
    };

    # /persist must be mounted in stage 1 so secrets/host keys are available
    # before the rest of the system comes up. Guard the whole fileSystems
    # entry, not just the value — assigning into fileSystems."/persist" at
    # all (even via mkIf) declares that submodule, and non-impermanent
    # profiles never set its fsType, which fails eval.
    fileSystems = lib.mkIf isImpermanent {
      "/persist".neededForBoot = true;
    };
  };
}
