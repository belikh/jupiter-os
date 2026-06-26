{ config, pkgs, ... }:

{
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;
  networking.hostId = "00000000"; # Overridden by the host

  services.zfs.autoScrub.enable = true;
  services.zfs.trim.enable = true;

  # SMB Share scaffolding
  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        "workgroup" = "WORKGROUP";
        "server string" = "Jupiter OS NAS";
        "netbios name" = "jupiter-nas";
        "security" = "user";
      };
      "Public" = {
        "path" = "/tank/public";
        "browseable" = "yes";
        "read only" = "no";
        "guest ok" = "yes";
        "create mask" = "0644";
        "directory mask" = "0755";
      };
    };
  };

  services.samba-wsdd = {
    enable = true; # Makes the NAS discoverable in Windows
    openFirewall = true;
  };
}
