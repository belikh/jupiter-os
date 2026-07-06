{
  config,
  lib,
  ...
}:

# TCx Wave kiosk: jupiter-bedroom. The BOOTSTRAP host — the first machine of
# the rebuilt fleet, and the canonical template for its siblings. Also the
# fleet's MQTT broker: every dashboard kiosk's ha-agent publishes here.
# Everything common to the 4 kiosks (kiosk session, touch-wake, ha-agent,
# power tuning, impermanence, boot splash) is inherited from
# modules/desktop/tcxwave-kiosk.nix; this file holds only what is unique to
# amalthea — its identity, its disk, its dashboard URL, and the broker.
{
  imports = [
    ../../modules/common.nix
    ../../modules/desktop/tcxwave-kiosk.nix
    ../../modules/services/mqtt.nix
  ];

  networking.hostName = "amalthea";
  networking.hostId = "0515cf00"; # Stable per-host 8-char hex, required for ZFS

  jupiter.tcxWaveKiosk = {
    enable = true;
    dashboardUrl = "https://iot.jupiter.au/jupiter-room/quarters";
    disk = "/dev/disk/by-id/ata-SanDisk_SD9SN8W128G1011_204903800470";
  };

  # ── robcoterm cutover (task.md T4.4) ──────────────────────────────────────
  # Cage+Chromium is stopped here (the `kiosk` user it created in
  # dashboard-kiosk.nix stays — robcoterm runs as it). robcoterm then owns tty1
  # and the DRM scanout directly. Rollback = revert this block (cage comes back
  # via the tcxWaveKiosk profile). cage was already inactive on this box before
  # the cutover, so this is the first thing to actually light the panel.
  # NOTE: robcoterm does not yet own DPMS/idle (Phase 4.1/4.2 code is unwired),
  # so the screen won't sleep until that lands — acceptable for the bring-up.
  services.cage.enable = lib.mkForce false;

  sops.secrets.robcoterm_ha_token_amalthea.owner = "kiosk";

  jupiter.robcotermKiosk = {
    enable = true;
    room = "bedroom";
    haTokenFile = config.sops.secrets.robcoterm_ha_token_amalthea.path;
  };

  # Broker runs locally on amalthea — point ha-agent at localhost instead of
  # the profile's amalthea.localdomain default.
  jupiter.services.haAgent.mqttHost = "localhost";

  sops.secrets.mqtt_homeassistant = { };

  jupiter.services.mqtt = {
    enable = true;
    users = {
      homeassistant = {
        passwordFile = config.sops.secrets.mqtt_homeassistant.path;
        acl = [ "readwrite #" ];
      };
      ha-linux-agent = {
        passwordFile = config.sops.secrets.mqtt_ha_linux_agent.path;
        acl = [
          "readwrite homeassistant/#"
          "readwrite ha-linux-agent/#"
        ];
      };
    };
  };
}
