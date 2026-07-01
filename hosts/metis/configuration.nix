{
  config,
  pkgs,
  lib,
  ...
}:

# TCx Wave kiosk: kitchen. One of 4 identical 6140-E45 units (see
# modules/services/tcxwave-power-tuning.nix for the shared hardware tuning) —
# each is its own host because each points at a different room's Home
# Assistant dashboard and can't share a hostName/hostId with the others.
{
  imports = [
    ../../modules/common-stateful.nix
    ../../modules/services/tcxwave-power-tuning.nix # kernel/GPU/storage/power tuning for the 6140-E45's i5-6300U + HD 520 hardware
    ../../modules/desktop/dashboard-kiosk.nix
    ../../modules/desktop/dashboard-gaming.nix # optional dual-VT kiosk + gaming session (off by default)
  ];

  # Stateless kiosk appliance: erase-your-darlings root so the box always boots
  # to a known-pristine state and can't accumulate drift. Only a minimal set
  # plus the kiosk Chromium profile survives (below).
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

  # Branding (GRUB + Fallout theme + verbose preDeviceCommands banner) is left
  # off here — it's the single biggest boot-time cost on these units, and
  # they're wall-mounted dashboards nobody watches POST on. Plain, fast
  # systemd-boot instead. (Branding is opt-in fleet-wide; see common.nix.)

  networking.hostName = "metis";
  networking.hostId = "5e0dc488"; # Stable per-host 8-char hex, required for ZFS

  jupiter.dashboardKiosk = {
    enable = true;
    url = "https://ha.jupiter.au/kitchen";
  };

  # Integrated 15" PCAP touchscreen: NO custom/kernel driver needed. The panel
  # is a USB HID multitouch device handled in-tree by `hid-multitouch`, and
  # cage/wlroots consumes it via libinput. (Toshiba's "driver kit" exists only
  # for old SLES — SLE 12 SP2, kernel ~4.4, 2017 — where the in-tree quirk
  # wasn't yet present; irrelevant on our linuxPackages_latest.) If, on a real
  # unit, touch is offset or the panel is mounted rotated, that's a userspace
  # calibration matrix — NOT a driver — applied via a udev/libinput rule, e.g.:
  #   services.udev.extraHwdb = ''
  #     # 90° clockwise: LIBINPUT_CALIBRATION_MATRIX=0 1 0 -1 0 1
  #     evdev:name:*Touch*:* ENV{LIBINPUT_CALIBRATION_MATRIX}="..."
  #   '';
  # Left out until verified on hardware so we don't ship a wrong transform.

  # Optional: turn this unit into a dual-session box — the dashboard kiosk on
  # VT 6 and a Bazzite-style gamescope/Steam session on VT 7, flipped at
  # runtime with `jupiter-mode {dashboard|gaming|toggle}` (run as root over
  # SSH; chvt needs CAP_SYS_TTY_CONFIG) or via Home Assistant (see below).
  # Reuses the Cage program/user from jupiter.dashboardKiosk above. The Intel
  # HD 520 suits light/streamed/emulated play, not AAA, and TLP keeps the CPU
  # in powersave — see modules/services/tcxwave-power-tuning.nix.
  jupiter.dashboardGaming = {
    enable = false;
    # When enabled, HA gets two switches ("Switch to Dashboard" / "Switch to
    # Gaming") via jupiter.services.haAgent's backend-launcher — see
    # modules/desktop/dashboard-gaming.nix for the full mechanism (it wires
    # jupiter.services.haAgent itself; nothing more to set here).
    homeAssistant.enable = true;
  };
}
