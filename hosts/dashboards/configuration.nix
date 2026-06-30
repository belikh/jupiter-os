{ config, pkgs, lib, ... }:

{
  imports = [
    ../../modules/common-stateful.nix
    ../../modules/services/tcxwave-power-tuning.nix # kernel/GPU/storage/power tuning for the 6140-E45's i5-6300U + HD 520 hardware
    ../../modules/desktop/dashboard-gaming.nix # optional dual-VT kiosk + gaming session (off by default)
  ];

  # Stateless kiosk appliance: erase-your-darlings root so the box always boots
  # to a known-pristine state and can't accumulate drift. Only a minimal set
  # plus the kiosk Chromium profile survives (below).
  # ⚠️ disk is a REPLACE-ME placeholder — set the real by-id path before install.
  jupiter.storage = {
    profile = "impermanent";
    disk = "/dev/disk/by-id/REPLACE-ME-dashboard-os-disk";
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

  networking.hostName = "jupiter-dashboard";
  networking.hostId = "da58b0a4"; # Stable per-host 8-char hex, required for ZFS

  # Kiosk Mode using Cage (Wayland) + Chromium
  services.xserver.enable = false; # Wayland is lighter and faster for kiosks

  services.cage = {
    enable = true;
    user = "kiosk";
    # Loads the Home Assistant jupiter-ops dashboard directly. The extra flags
    # are power/perf, not behavioural: native Wayland (no XWayland probing),
    # VA-API hardware video decode on the HD 520 iGPU (offloads the CPU), and
    # trimming background networking/sync/updates that would otherwise wake
    # the box for no benefit on a single-purpose kiosk.
    program = "${pkgs.chromium}/bin/chromium --kiosk --incognito --app=https://ha.jupiter.au/jupiter-ops --ozone-platform=wayland --use-gl=egl --enable-features=VaapiVideoDecoder,VaapiIgnoreDriverChecks --disable-background-networking --disable-sync --disable-translate --disable-component-update --disable-extensions --no-first-run";
  };

  users.users.kiosk = {
    isNormalUser = true;
    # "render" grants access to /dev/dri/renderD* for VA-API hardware decode.
    extraGroups = [
      "video"
      "render"
    ];
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

  # Optional: turn one of these units into a dual-session box — the dashboard
  # kiosk on VT 6 and a Bazzite-style gamescope/Steam session on VT 7, flipped
  # at runtime with `jupiter-mode {dashboard|gaming|toggle}` (run as root over
  # SSH; chvt needs CAP_SYS_TTY_CONFIG). Reuses the Cage program/user above.
  #
  # NOTE: all four dashboards share this single config + hostId, so enabling
  # here turns the whole fleet into gaming boxes. To do just one unit, split it
  # into its own host (own hostId/deploy node) and set this there. The Intel HD
  # 520 suits light/streamed/emulated play, not AAA, and TLP keeps the CPU in
  # powersave — see modules/services/tcxwave-power-tuning.nix.
  # Only required once the dual-VT/gaming feature is switched on, so a plain
  # dashboard deploy doesn't depend on the MQTT secret existing.
  sops.secrets = lib.mkIf config.jupiter.dashboardGaming.enable {
    mqtt_dashboard = { };
  };

  jupiter.dashboardGaming = {
    enable = false;
    # When enabled, Home Assistant auto-discovers a "Display Mode" select
    # (Dashboard/Gaming) and drives the active VT over MQTT, with live state.
    # Broker runs on lenovo (10.1.1.20); authenticates as the "dashboard" user
    # using the shared sops password (add mqtt_dashboard to secrets.yaml).
    homeAssistant = {
      enable = true;
      broker = "10.1.1.20";
      username = "dashboard";
      passwordFile = config.sops.secrets.mqtt_dashboard.path;
    };
  };
}
