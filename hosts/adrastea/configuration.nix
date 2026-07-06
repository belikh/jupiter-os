{ ... }:

# TCx Wave kiosk: office. One of 4 identical 6140-E45 units — a clone of
# amalthea minus the broker role. All shared behavior lives in
# modules/desktop/tcxwave-kiosk.nix; this file holds only what differs per
# unit: hostName, hostId, the OS disk, and the dashboard URL. Each unit is
# its own host only because each points at a different room's Home Assistant
# dashboard and can't share an identity.
{
  imports = [
    ../../modules/common.nix
    ../../modules/desktop/tcxwave-kiosk.nix
  ];

  networking.hostName = "adrastea";
  networking.hostId = "73c2a70f"; # Stable per-host 8-char hex, required for ZFS

  jupiter.tcxWaveKiosk = {
    enable = true;
    dashboardUrl = "https://iot.jupiter.au/office-command/office";
    disk = "/dev/disk/by-id/REPLACE-ME-adrastea-os-disk"; # set real by-id before install
  };
}
