{
  config,
  pkgs,
  lib,
  ...
}:

# Shared ZFS-on-root disko layouts, selected per host by an opinionated
# `jupiter.storage.profile`. Replaces the old per-host `disko.nix` boilerplate
# for the simple single-OS-disk hosts. Hosts with bespoke multi-pool layouts
# (the NAS) keep their own `disko.nix` and leave `profile = "none"`.
#
# Profiles:
#   impermanent  rpool/{local/root@blank, local/nix, safe/persist}; root rolls
#                back to @blank every boot (erase-your-darlings). Pair with
#                jupiter.core.impermanence to choose what survives. For
#                appliances/workstations (laptop, kiosks).
#   stateful     rpool/{root, nix, var}; persistent root, no rollback. For
#                always-on servers whose state must not be wiped on reboot.
#   minimal      rpool/{root, nix}; persistent root, no extra datasets. For
#                simple stateless boxes with nothing under a separate /var.
#   none         contributes nothing (default) — the host declares its own
#                disko layout, or is diskless.

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
        defaults to a placeholder that fails the assertion below — set it to
        the real /dev/disk/by-id path before installing.
      '';
    };

    espSize = lib.mkOption {
      type = lib.types.str;
      default = "1G";
      description = "Size of the EFI System Partition.";
    };
  };

  config = lib.mkIf (cfg.profile != "none") {
    # ZFS lags the kernel: nixpkgs currently declares 7.0 as the newest kernel
    # series the zfs module builds against (see
    # pkgs/os-specific/linux/zfs/generic.nix's kernelMaxSupportedMajorMinor).
    # A host with a ZFS-on-root profile needs a kernel ZFS actually supports
    # more than it needs the fleet-wide CachyOS default (modules/common.nix)
    # or any host-specific pick (e.g. the TCx Wave kiosks' linuxPackages_latest
    # power tuning) — mkForce so this wins over both. Bump the version here in
    # lockstep whenever nixpkgs raises zfs's kernelMaxSupportedMajorMinor.
    boot.kernelPackages = lib.mkForce pkgs.linuxPackages_7_0;

    # The ESP this module declares below (disko.devices, type EF00) is a UEFI
    # System Partition — so give every host that gets one from here a working
    # UEFI GRUB default tied to it, rather than leaving hosts with no
    # `jupiter.branding.enable` (which happens to be the only place that
    # currently sets `efiSupport`/`device`) with NixOS's bare defaults
    # (`device = ""`, `efiSupport = false`), which can't actually install:
    # legacy-BIOS GRUB needs a real block device, and this GPT layout has no
    # BIOS boot partition for it to embed into. mkDefault so branding.nix (or
    # any host) can still override.
    boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
    boot.loader.grub = {
      efiSupport = lib.mkDefault true;
      device = lib.mkDefault "nodev";
    };

    # Automatic central-backup wiring: a server's state dataset replicates to the
    # NAS by default. Appliances/workstations (impermanent) don't — their data
    # roams via Syncthing or is reproducible. Hosts can override jupiter.backup.
    jupiter.backup = {
      enable = lib.mkDefault (cfg.profile == "stateful");
      datasets = lib.mkDefault (
        if cfg.profile == "stateful" then
          [ "rpool/var" ]
        else if cfg.profile == "impermanent" then
          [ "rpool/safe/persist" ]
        else
          [ ]
      );
    };

    # A warning, not a hard assertion: no hardware is provisioned yet for any
    # host in this fleet (see docs/roadmap.md), so a REPLACE-ME disk is the
    # expected pre-deployment state everywhere and must not block `nix build`
    # / `nix flake check` / CI. The placeholder path doesn't exist on disk, so
    # disko itself will simply fail loudly ("no such device") if someone tries
    # to actually install against it — this is just an earlier, friendlier
    # nudge to fill in the real /dev/disk/by-id path first.
    warnings = lib.optional (lib.hasInfix "REPLACE-ME" cfg.disk) ''
      jupiter.storage.disk on host "${config.networking.hostName}" is still
      the REPLACE-ME placeholder. disko will WIPE whatever device this
      points at, so set it to the real /dev/disk/by-id path of the OS disk
      before installing (see docs/09-operations.md):
        ls -l /dev/disk/by-id/   # pick the OS SSD/NVMe, NOT a data disk
    '';

    # Erase-your-darlings: roll the root dataset back to its @blank snapshot in
    # initrd, before the root is mounted. Only meaningful for the impermanent
    # profile.
    boot.initrd.systemd.services.rollback = lib.mkIf isImpermanent {
      description = "Rollback root ZFS dataset to a pristine state";
      wantedBy = [ "initrd.target" ];
      after = [ "zfs-import-rpool.service" ];
      before = [ "sysroot.mount" ];
      path = [ pkgs.zfs ];
      unitConfig.DefaultDependencies = "no";
      serviceConfig.Type = "oneshot";
      # Guard on the snapshot existing: a no-op if the pool isn't present (e.g.
      # a synthesized build-vm during CI), and we'd rather skip than wedge boot
      # if the @blank snapshot is somehow missing on real hardware.
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
