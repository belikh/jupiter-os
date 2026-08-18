{
  config,
  lib,
  pkgs,
  ...
}:

# BIOS/firmware deployment for libretro cores that require it.
# BIOS files are non-redistributable binary blobs (copyrighted firmware).
# They live on europa's pool under /tank/archive/retro/bios/<system>/,
# deployed by the operator once (manual step, not in git), and synced to
# kiosks via NFS at activation time alongside the ROM datasets.
# This replaces the manual "operator drops files on each kiosk" workflow.

let
  cfg = config.jupiter.bios;
in
{
  options.jupiter.bios = {
    enable = lib.mkEnableOption ''
      Deploy BIOS/firmware files needed by libretro cores into
      ~/.config/retroarch/system/ on kiosks. Files are sourced from
      europa's pool (NFS mount at <nfsBiosRoot>/<system>/) and installed
      at activation time. Only the BIOS files for enabled systems are deployed.
    '';

    # NFS host serving the BIOS files (defaults to europa)
    nfsHost = lib.mkOption {
      type = lib.types.str;
      default = config.jupiter.fleet.addresses.europa;
      description = "NFS host serving the BIOS tree.";
    };

    # Root path on the NFS host where per-system BIOS dirs live
    nfsBiosRoot = lib.mkOption {
      type = lib.types.str;
      default = "/tank/archive/retro/bios";
      description = "Path on NFS host containing <system>/ subdirs with BIOS files.";
    };

    # Mount point for the read-only BIOS NFS mount
    mountBase = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/europa-bios";
      description = "Local mount point for the read-only BIOS NFS mount.";
    };

    # Which systems need BIOS files deployed (keys from cartridge-catalogue.tsv)
    # Only these systems' BIOS dirs will be mounted and synced.
    systems = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "fds" ]; # Only FDS needs BIOS (disksys.rom) in current catalogue
      description = "System keys that need BIOS files deployed.";
    };

    sessionUser = lib.mkOption {
      type = lib.types.str;
      default = "gamer";
      description = "User whose retroarch system directory receives the BIOS files.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Ensure the retroarch system directory exists (impermanence persists it)
    systemd.tmpfiles.rules = [
      "d /home/${cfg.sessionUser}/.config/retroarch/system 0755 ${cfg.sessionUser} users -"
    ];

    # One read-only NFS mount for the BIOS tree (idle-expires like cartridge mounts)
    fileSystems."${cfg.mountBase}" = {
      device = "${cfg.nfsHost}:${cfg.nfsBiosRoot}";
      fsType = "nfs";
      options = [
        "ro"
        "soft"
        "noatime"
        "x-systemd.automount"
        "x-systemd.idle-timeout=300"
      ];
    };

    # Deploy BIOS files for each enabled system that has a BIOS dir on the NAS
    systemd.services."jupiter-bios-deploy" = {
      description = "Deploy BIOS/firmware files to retroarch system directory";
      wantedBy = [ "multi-user.target" ];
      before = [ "jupiter-arcade.service" ];
      after = [ "mnt-europa-bios.mount" ];
      requires = [ "mnt-europa-bios.mount" ];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.sessionUser;
        Group = "users";
        path = [
          pkgs.coreutils
          pkgs.rsync
        ];
      };
      script = ''
        set -euo pipefail
        BIOS_DIR="/home/${cfg.sessionUser}/.config/retroarch/system"
        SRC_ROOT="${cfg.mountBase}"
        mkdir -p "$BIOS_DIR"

        ${lib.concatMapStringsSep "\n" (sys: ''
          SYS_DIR="$SRC_ROOT/${sys}"
          if [ -d "$SYS_DIR" ]; then
            rsync -a --ignore-existing "$SYS_DIR/" "$BIOS_DIR/"
            echo "jupiter-bios: synced ${sys} BIOS from $SYS_DIR"
          else
            echo "jupiter-bios: no BIOS dir for ${sys} at $SYS_DIR (skipping)"
          fi
        '') cfg.systems}
      '';
    };
  };
}
