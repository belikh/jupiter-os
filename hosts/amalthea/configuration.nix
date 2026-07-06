{
  config,
  pkgs,
  lib,
  ...
}:

# TCx Wave kiosk: jupiter-bedroom. The BOOTSTRAP host — the first machine of
# the rebuilt fleet, brought up standalone, and the canonical template for its
# siblings. One of 4 identical 6140-E45 units (see
# modules/services/tcxwave-power-tuning.nix for the shared hardware tuning);
# metis/adrastea/thebe are clones of this file differing only in
# hostName/hostId/dashboard URL/disk.
{
  imports = [
    ../../modules/common.nix
    ../../modules/services/tcxwave-power-tuning.nix
    ../../modules/services/tcxwave-touch-wake.nix
    ../../modules/desktop/dashboard-kiosk.nix
    ../../modules/services/mqtt.nix
    ../../modules/services/ha-agent.nix
  ];

  networking.hostName = "amalthea";
  networking.hostId = "0515cf00"; # Stable per-host 8-char hex, required for ZFS

  # Stateless kiosk appliance: erase-your-darlings root so the box always
  # boots to a known-pristine state and can't accumulate drift.
  jupiter.storage = {
    profile = "impermanent";
    disk = "/dev/disk/by-id/ata-SanDisk_SD9SN8W128G1011_204903800470";
  };

  jupiter.core.impermanence = {
    enable = true;
    persistAdminHome = false; # no personal session on a kiosk
    # Keep the Chromium profile so the HA dashboard's session/cache survive
    # reboots (faster warm-up, stays logged in).
    users.kiosk = {
      directories = [
        ".config/chromium"
        ".cache/chromium"
      ];
    };
    users.io = {
      directories = [
        ".gemini"
      ];
    };
  };

  jupiter.dashboardKiosk = {
    enable = true;
    url = "https://iot.jupiter.au/jupiter-room/quarters";
  };

  jupiter.touchWake = {
    enable = true;
    idleTimeout = 300; # 5 minutes
  };

  # MQTT broker configuration (running locally on amalthea for now)
  sops.secrets.mqtt_homeassistant = { };
  sops.secrets.mqtt_ha_linux_agent = { };

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

  # Home Assistant Linux Agent
  jupiter.services.haAgent = {
    enable = true;
    mqttHost = "localhost";
    launcherApps = [
      {
        id = "screen-power";
        name = "Bedroom Kiosk Screen";
        unit = "tcxwave-screen-power.service";
        scope = "system";
        icon = "mdi:monitor";
      }
    ];
  };

  # Integrated 15" PCAP touchscreen: NO custom/kernel driver needed. The panel
  # is a USB HID multitouch device handled in-tree by `hid-multitouch`, and
  # cage/wlroots consumes it via libinput. If, on a real unit, touch is offset
  # or the panel is mounted rotated, that's a userspace calibration matrix —
  # NOT a driver — applied via a udev/libinput rule, e.g.:
  #   services.udev.extraHwdb = ''
  #     # 90° clockwise: LIBINPUT_CALIBRATION_MATRIX=0 1 0 -1 0 1
  #     evdev:name:*Touch*:* ENV{LIBINPUT_CALIBRATION_MATRIX}="..."
  #   '';
  # Left out until verified on hardware so we don't ship a wrong transform.
}
