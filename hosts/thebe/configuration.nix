{ ... }:

# TCx Wave kiosk: robbie-room. One of 4 identical 6140-E45 units — a clone of
# amalthea minus the broker role. All shared behavior lives in
# modules/desktop/tcxwave-kiosk.nix; this file holds only what differs per
# unit: hostName, hostId, the OS disk, the dashboard URL, and (uniquely among
# the fleet) its USB Wi-Fi adapter — the other three are wired. Each unit is
# its own host only because each points at a different room's Home Assistant
# dashboard and can't share an identity.
{
  imports = [
    ../../modules/common.nix
    ../../modules/desktop/tcxwave-kiosk.nix
  ];

  networking.hostName = "thebe";
  networking.hostId = "af54f5c3"; # Stable per-host 8-char hex, required for ZFS

  jupiter.tcxWaveKiosk = {
    enable = true;
    dashboardUrl = "https://iot.jupiter.au/robert-room/quarters";
    disk = "/dev/disk/by-id/ata-SanDisk_SD9SN8W128G1011_204903800540";
    wifi.enable = true; # NetGear A6210 / MediaTek MT7612U USB adapter
  };
}
