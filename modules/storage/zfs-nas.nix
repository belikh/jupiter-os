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
# Current state (2026-07-13): tank is a single 8.2T vdev on sdb1 (WD 18TB).
# The second WD 18TB (sdc) is receiving file transfers — once empty it will be
# wiped and attached as a mirror via `zpool attach`. See the plan appendix for
# the procedure.

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
      name = "tank/services/attic";
      mountpoint = "/tank/services/attic";
      recordsize = "256K";
    }
    {
      # Persistent state for callisto (diskless netbooted) — SSH host keys,
      # sops-nix state, /var/log, etc. Exported back to callisto over NFS
      # (see modules/storage/nas-nfs.nix) and bind-mounted into place on the
      # build host via impermanence (modules/core/impermanence.nix). Closes
      # the runtime-secret gap noted in hosts/callisto/configuration.nix.
      name = "tank/services/callisto";
      mountpoint = "/tank/services/callisto";
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
      enable = true;
      openFirewall = true;
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
      enable = true; # Makes the NAS discoverable on the network
      openFirewall = true;
    };

    environment.systemPackages = with pkgs; [
      zfs
      samba
      sanoid # provides syncoid too, for manual runs
    ];
  };
}
