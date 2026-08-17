{
  config,
  lib,
  pkgs,
  ...
}:

# Syncthing hub — store the canonical synced copy on protected storage
# (tank/personal on the NAS) instead of the OS disk, so roaming personal data
# is fully protected by the ZFS mirror + sanoid snapshots + restic offsite.
# Folders created in the WebUI live under dataDir.

let
  cfg = config.jupiter.services.syncthing;
in
{
  options.jupiter.services.syncthing = {
    enable = lib.mkEnableOption "Syncthing for user io";

    exposeLan = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Bind the GUI to all interfaces and open its port. The WebUI is the
        device/folder management plane (overrideDevices/overrideFolders are
        false below) and Syncthing applies its own admin/GUI auth only to
        non-local connections — loopback-only is the safe default. Flip on
        only where the LAN is an accepted trust boundary (europa does).
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/home/io";
      description = ''
        Base directory for Syncthing's data, config/index, and the default
        location for new folders. On personal machines this is io's home
        (/home/io). On the NAS hub set it to a path on protected storage
        (e.g. /tank/personal) so the canonical synced copy is redundant,
        snapshotted, and in the offsite path — not stranded on the OS disk.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.syncthing = {
      enable = true;
      user = "io";
      dataDir = cfg.dataDir;
      configDir = "${cfg.dataDir}/.config/syncthing";
      overrideDevices = false; # Let the user manage devices via WebUI
      overrideFolders = false; # Let the user manage folders via WebUI
      guiAddress = if cfg.exposeLan then "0.0.0.0:8384" else "127.0.0.1:8384";
      # Upstream covers 22000/tcp+udp + 21027/udp (discovery); the GUI port
      # is ours to open.
      openDefaultPorts = true;
    };

    networking.firewall.allowedTCPPorts = lib.optional cfg.exposeLan 8384;

    # Ensure the data dir exists and is owned by the service user. ZFS dataset
    # mountpoints (e.g. /tank/personal) are created root-owned by the NAS
    # dataset service; without this, syncthing fails on boot with
    # "mkdir <dataDir>: permission denied". tmpfiles enforces ownership
    # idempotently at boot.
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 io users -"
    ];
  };
}
