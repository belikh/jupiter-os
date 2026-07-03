{ ... }:

# TCx Wave kiosk: kitchen. One of 4 identical 6140-E45 units (see
# modules/services/tcxwave-power-tuning.nix for the shared hardware tuning
# and modules/desktop/dashboard-kiosk.nix for the shared kiosk session) —
# a clone of hosts/amalthea/configuration.nix, the bootstrap host, differing
# only in hostName/hostId/dashboard URL/disk. Each unit is its own host
# because each points at a different room's Home Assistant dashboard and
# can't share an identity.
{
  imports = [
    ../../modules/common.nix
    ../../modules/services/tcxwave-power-tuning.nix
    ../../modules/desktop/dashboard-kiosk.nix
  ];

  networking.hostName = "metis";
  networking.hostId = "5e0dc488"; # Stable per-host 8-char hex, required for ZFS

  # Stateless kiosk appliance: erase-your-darlings root so the box always
  # boots to a known-pristine state and can't accumulate drift.
  # ⚠️ disk is a REPLACE-ME placeholder — set the real by-id path before install.
  jupiter.storage = {
    profile = "impermanent";
    disk = "/dev/disk/by-id/REPLACE-ME-metis-os-disk";
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
  };

  jupiter.dashboardKiosk = {
    enable = true;
    url = "https://ha.jupiter.au/kitchen";
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
