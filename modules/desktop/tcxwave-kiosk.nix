{
  config,
  lib,
  ...
}:

# Shared appliance profile for the 4 TCx Wave dashboard kiosks
# (amalthea/metis/adrastea/thebe) — identical 6140-E45 units, one per room.
# Every behavioral concern that is the same across the fleet lives here so the
# per-host files can hold ONLY what actually differs per unit: hostName,
# hostId, the OS disk by-id, and the dashboard URL (plus thebe's Wi-Fi).
#
# Add new kiosk features HERE, not in hosts/<name>/configuration.nix, or the
# fleet will drift again — that is exactly how thebe lost touch-wake and the
# ha-agent launcherApps while amalthea kept them.
#
# The one intentional fleet asymmetry: amalthea also runs the mosquitto broker
# (modules/services/mqtt.nix) and overrides ha-agent's mqttHost to localhost;
# the other three are broker clients pointed at amalthea.localdomain. The
# broker is infrastructure, not a dashboard feature, so it stays in amalthea's
# host file rather than being pulled in here.

let
  cfg = config.jupiter.tcxWaveKiosk;
in
{
  imports = [
    ../services/tcxwave-power-tuning.nix
    ../services/tcxwave-touch-wake.nix
    ../services/ha-agent.nix
    ./dashboard-kiosk.nix
  ];

  options.jupiter.tcxWaveKiosk = {
    enable = lib.mkEnableOption "TCx Wave dashboard kiosk appliance profile";

    dashboardUrl = lib.mkOption {
      type = lib.types.str;
      description = "Home Assistant dashboard URL this unit displays full-screen.";
      example = "https://iot.jupiter.au/main-floor/main";
    };

    disk = lib.mkOption {
      type = lib.types.str;
      description = ''
        OS disk /dev/disk/by-id path. disko will WIPE this device on install,
        so point it at the unit's real OS SSD/NVMe (NOT a data disk). Leave
        the REPLACE-ME placeholder on units that aren't installed yet.
      '';
    };

    wifi = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Join Wi-Fi via the USB adapter (thebe) instead of wired ethernet.
          A no-op on the wired units, which have a default route within ~1s
          of boot regardless.
        '';
      };

      network = lib.mkOption {
        type = lib.types.str;
        default = "jupiter.au";
        description = "SSID to join when wifi is enabled.";
      };

      psk = lib.mkOption {
        type = lib.types.str;
        default = "lolcats66";
        description = "WPA PSK for the SSID.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Stateless kiosk appliance: erase-your-darlings root so the box always
    # boots to a known-pristine state and can't accumulate drift.
    jupiter.storage = {
      profile = "impermanent";
      disk = cfg.disk;
    };

    jupiter.core.impermanence = {
      enable = true;
      persistAdminHome = false; # no personal session on a kiosk
      # Keep the Chromium profile so the HA dashboard's session/cache survive
      # reboots (faster warm-up, stays logged in), plus the admin (io) CLI
      # configs that are annoying to re-establish after an erase.
      users.kiosk.directories = [
        ".config/chromium"
        ".cache/chromium"
      ];
      users.io.directories = [
        ".gemini"
      ];
    };

    jupiter.dashboardKiosk = {
      enable = true;
      url = cfg.dashboardUrl;
    };

    jupiter.boot.falloutSplash.enable = true;

    # Touch-wake: power the panel off after idleTimeout and wake it on touch.
    # Exposes tcxwave-screen-power.service, which ha-agent surfaces as the
    # "screen-power" HA switch below.
    jupiter.touchWake = {
      enable = true;
      idleTimeout = 300; # 5 minutes
    };

    sops.secrets.mqtt_ha_linux_agent = { };

    # ha-agent publishes CPU/governor/EPP sensors to the broker and exposes
    # the touch-wake screen-power unit as a Home Assistant switch. mqttHost
    # defaults to the amalthea broker; amalthea itself overrides it to
    # localhost since the broker runs there.
    jupiter.services.haAgent = {
      enable = true;
      mqttHost = lib.mkDefault "amalthea.localdomain";
      launcherApps = [
        {
          id = "screen-power";
          name = "${config.networking.hostName} screen";
          unit = "tcxwave-screen-power.service";
          scope = "system";
          icon = "mdi:monitor";
        }
      ];
    };

    # USB Wi-Fi adapter (NetGear A6210 / MediaTek MT7612U). Only thebe has one;
    # the wired kiosks leave wifi.enable at its false default.
    networking.wireless = lib.mkIf cfg.wifi.enable {
      enable = true;
      networks."${cfg.wifi.network}".psk = cfg.wifi.psk;
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
  };
}
