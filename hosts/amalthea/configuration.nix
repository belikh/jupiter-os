{
  ...
}:

# TCx Wave kiosk: jupiter-bedroom. The BOOTSTRAP host — the first machine of
# the rebuilt fleet, and the canonical template for its siblings. Everything
# common to the 4 kiosks (kiosk session, touch-wake, ha-agent, power tuning,
# impermanence, boot splash) is inherited from modules/desktop/tcxwave-kiosk.nix;
# this file holds only what is unique to amalthea — its identity, its disk,
# and its dashboard URL. (The MQTT broker used to live here too; it moved to
# callisto 2026-07-24 — see modules/desktop/tcxwave-kiosk.nix.)
{
  imports = [
    ../../modules/common.nix
    ../../modules/desktop/tcxwave-kiosk.nix
  ];

  networking.hostName = "amalthea";
  networking.hostId = "0515cf00"; # Stable per-host 8-char hex, required for ZFS

  jupiter.tcxWaveKiosk = {
    enable = true;
    dashboardUrl = "https://iot.jupiter.au/jupiter-room/quarters";
    disk = "/dev/disk/by-id/ata-SanDisk_SD9SN8W128G1011_204903800470";
  };
}
