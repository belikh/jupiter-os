{ config, pkgs, ... }:

{
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;

  # Import both data pools at boot via their ZFS-native mountpoints.
  # Neither is managed by disko (disko only owns the OS SSD) — both are created
  # by hand during migration (scratchpad/nas-migration.md) and only imported here.
  #
  #   tank   = mirror(18TB + 18TB)  -> NEW primary, new dataset structure
  #   europa = mirror(10TB + 10TB)  -> FROZEN ARCHIVE (legacy data, read-only).
  #            Set `zfs set readonly=on europa` once during migration; we never
  #            restructure it. Reorganised into tank at the user's leisure later.
  boot.zfs.extraPools = [ "tank" "europa" ];

  # Pool maintenance
  services.zfs.autoScrub.enable = true;
  services.zfs.trim.enable = true;

  # ---- SMB shares (suited to the wider network) ----------------------------
  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        "workgroup" = "WORKGROUP";
        "server string" = "Jupiter OS NAS";
        "netbios name" = "jupiter-nas";
        "security" = "user";
        "map to guest" = "bad user";
      };

      # New media library — writable for the admin/*arr stack, browseable on LAN.
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

      # Legacy europa data exposed strictly READ-ONLY so it stays untouched.
      "archive" = {
        "path" = "/europa";
        "browseable" = "yes";
        "read only" = "yes";
        "guest ok" = "no";
        "valid users" = "io";
      };
    };
  };

  services.samba-wsdd = {
    enable = true; # Makes the NAS discoverable in Windows
    openFirewall = true;
  };
}
