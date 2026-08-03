{
  config,
  pkgs,
  lib,
  ...
}:

# ZFS NAS layer — pool import, declarative datasets, and Samba shares.
#
# disko manages ONLY the OS SSD. The data pool(s) are created/managed by hand
# and imported here. Datasets are created idempotently by a oneshot service at
# boot so new datasets appear without manual `zfs create`.
#
# Current state (2026-07-20): tank is a 16.4T two-disk mirror across the WD
# 18TB drives, using whole-disk vdevs (ZFS-managed GPT — pool members are
# addressed by-id with no -partN suffix, so `zpool replace` can rebuild the
# layout on a new disk automatically). autoexpand=on; all OpenZFS 2.4.3
# feature flags enabled. Built via the attach-then-grow sequence (whole-disk
# vdev attach, then replace the legacy partition member with a second
# whole-disk vdev).

let
  cfg = config.jupiter.nas;

  # Datasets to create on tank. Each entry is { name, mountpoint, recordsize }.
  # Existing datasets (like tank/junk) are NOT listed — they're left alone.
  tankDatasets = [
    {
      name = "tank/personal";
      mountpoint = "/tank/personal";
      recordsize = "128K";
    }
    {
      name = "tank/media";
      mountpoint = "/tank/media";
      recordsize = "1M";
    }
    {
      name = "tank/backups";
      mountpoint = "/tank/backups";
      recordsize = "128K";
    }
    {
      name = "tank/services";
      mountpoint = "/tank/services";
      recordsize = "128K";
    }
    {
      name = "tank/surveillance";
      mountpoint = "/tank/surveillance";
      recordsize = "1M";
    }
    {
      name = "tank/downloads";
      mountpoint = "/tank/downloads";
      recordsize = "1M";
    }
    {
      name = "tank/vm";
      mountpoint = "/tank/vm";
      recordsize = "64K";
    }
    # Retro gaming archive for jupiterOS Arcade (served via NFS to kiosks)
    {
      name = "tank/archive";
      mountpoint = "/tank/archive";
      recordsize = "1M";
    }
    {
      name = "tank/archive/retro";
      mountpoint = "/tank/archive/retro";
      recordsize = "1M";
    }
    {
      name = "tank/archive/retro/games";
      mountpoint = "/tank/archive/retro/games";
      recordsize = "1M";
    }
    {
      name = "tank/archive/retro/games/curated";
      mountpoint = "/tank/archive/retro/games/curated";
      recordsize = "1M";
    }
    # Cartridge ROMs (NES/SNES/GB/GBC/GBA/N64/...). Small leaf files (KB-MB)
    # read directly by retroarch over NFS — a small recordsize avoids ARC waste
    # and read-amplification across thousands of tiny ROMs. Single dataset with
    # per-system directory children (no child datasets), so one NFS mount sees
    # every system subdir — sidesteps the crossmnt-submount trap the eXo
    # overlayfs layer has to mount around (modules/desktop/exodos.nix).
    {
      name = "tank/archive/retro/games/cartridge";
      mountpoint = "/tank/archive/retro/games/cartridge";
      recordsize = "64K";
    }
    # Optical disc images (PS1/Saturn/GameCube/Wii CHD). Large immutable files
    # → 1M recordsize for compression. Wired later (not in this change).
    {
      name = "tank/archive/retro/games/optical";
      mountpoint = "/tank/archive/retro/games/optical";
      recordsize = "1M";
    }
    # Modern-era disc/card images (3DS/Wii U/PS3). Isolated on its own dataset
    # so a runaway import or scrub can't block cartridge reads. Wired later.
    {
      name = "tank/archive/retro/games/modern";
      mountpoint = "/tank/archive/retro/games/modern";
      recordsize = "1M";
    }
    # Staging ground for in-flight torrent downloads (aria2 → cache/incoming).
    # NOT exported to kiosks; promotion to games/cartridge happens only after
    # igir hash verification (modules/services/rom-acquire.nix).
    {
      name = "tank/archive/retro/cache";
      mountpoint = "/tank/archive/retro/cache";
      recordsize = "1M";
    }
    {
      name = "tank/archive/retro/scratch";
      mountpoint = "/tank/archive/retro/scratch";
      recordsize = "1M";
    }
    {
      name = "tank/archive/retro/downloads";
      mountpoint = "/tank/archive/retro/downloads";
      recordsize = "1M";
    }
    {
      name = "tank/archive/retro/metadata";
      mountpoint = "/tank/archive/retro/metadata";
      recordsize = "128K";
    }
    # No-Intro DAT packs (non-redistributable under No-Intro's terms — fetched
    # from DAT-o-Matic, never committed to the repo; see ADR-0001). Used by
    # igir to verify staged ROMs before promotion.
    {
      name = "tank/archive/retro/metadata/no-intro-dats";
      mountpoint = "/tank/archive/retro/metadata/no-intro-dats";
      recordsize = "128K";
    }
    # Skyscraper's source-agnostic scrape cache (CRC → metadata + art). Large;
    # regenerating it means re-hitting ScreenScraper/TGDB rate limits, so it is
    # its own dataset to snapshot and grow independently of the ROMs.
    {
      name = "tank/archive/retro/metadata/skyscraper-cache";
      mountpoint = "/tank/archive/retro/metadata/skyscraper-cache";
      recordsize = "128K";
    }
    # Generated fleet arcade inventory (inventory.json) — written by
    # modules/services/arcade-inventory.nix, consumed by `make status-arcade`.
    {
      name = "tank/archive/retro/state";
      mountpoint = "/tank/archive/retro/state";
      recordsize = "128K";
    }
    {
      name = "tank/archive/retro/metadata/pegasus";
      mountpoint = "/tank/archive/retro/metadata/pegasus";
      recordsize = "128K";
    }
    {
      name = "tank/archive/retro/metadata/pegasus/collections";
      mountpoint = "/tank/archive/retro/metadata/pegasus/collections";
      recordsize = "128K";
    }
    {
      name = "tank/archive/retro/metadata/pegasus/assets";
      mountpoint = "/tank/archive/retro/metadata/pegasus/assets";
      recordsize = "128K";
    }
    {
      name = "tank/archive/retro/metadata/dats";
      mountpoint = "/tank/archive/retro/metadata/dats";
      recordsize = "128K";
    }
  ];

  # Generate the idempotent create script.
  createScript = lib.concatMapStringsSep "\n" (ds: ''
    if ! ${pkgs.zfs}/bin/zfs list -H -o name ${ds.name} >/dev/null 2>&1; then
      echo "Creating ZFS dataset ${ds.name}"
      ${pkgs.zfs}/bin/zfs create \
        -o mountpoint=${ds.mountpoint} \
        -o compression=lz4 \
        -o recordsize=${ds.recordsize} \
        -p ${ds.name}
    fi
  '') tankDatasets;
in
{
  options.jupiter.nas = {
    enable = lib.mkEnableOption "the ZFS NAS layer (pool import, datasets, Samba)";
  };

  config = lib.mkIf cfg.enable {
    boot.supportedFilesystems = [ "zfs" ];
    boot.zfs.forceImportRoot = false;

    # Import the data pool at boot. Only tank — the legacy "europa" archive
    # pool's disks aren't attached (no 10TB drives present).
    boot.zfs.extraPools = [ "tank" ];

    # Disable ZFS automatic sharing (SMB shares are disabled)
    systemd.services.zfs-share.enable = false;

    # Pool maintenance
    services.zfs.autoScrub.enable = true;
    services.zfs.trim.enable = true;

    # Create declared datasets idempotently at boot, after the pool is imported.
    systemd.services.zfs-create-tank-datasets = {
      description = "Create declared ZFS datasets on tank (idempotent)";
      after = [ "zfs-import-tank.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.zfs ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = createScript;
    };

    # ---- SMB shares --------------------------------------------------------
    services.samba = {
      enable = false;
      openFirewall = false;
      settings = {
        global = {
          "workgroup" = "WORKGROUP";
          "server string" = "Jupiter OS NAS";
          "netbios name" = "jupiter-europa";
          "security" = "user";
          "map to guest" = "bad user";
        };

        # Media library — writable for the admin/*arr stack, browseable on LAN.
        "media" = {
          "path" = "/tank/media";
          "browseable" = "yes";
          "read only" = "no";
          "guest ok" = "no";
          "valid users" = "io";
          "create mask" = "0664";
          "directory mask" = "0775";
        };

        # Irreplaceable personal data — private.
        "personal" = {
          "path" = "/tank/personal";
          "browseable" = "yes";
          "read only" = "no";
          "guest ok" = "no";
          "valid users" = "io";
          "create mask" = "0644";
          "directory mask" = "0755";
        };

        # In-flight file transfer data — read-only share for monitoring.
        "junk" = {
          "path" = "/junk";
          "browseable" = "yes";
          "read only" = "yes";
          "guest ok" = "no";
          "valid users" = "io";
        };
      };
    };

    services.samba-wsdd = {
      enable = false;
      openFirewall = false;
    };

    environment.systemPackages = with pkgs; [
      zfs
      samba
      sanoid # provides syncoid too, for manual runs
    ];
  };
}
