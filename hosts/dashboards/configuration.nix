{ config, pkgs, lib, ... }:

{
  imports = [
    ../../modules/common-stateful.nix
    ./disko.nix # OS disk layout (destructive — confirm device before install)
    ../../modules/services/tcxwave-power-tuning.nix # kernel/GPU/storage/power tuning for the i5-6500U + HD 520 hardware
    ../../modules/desktop/dashboard-gaming.nix # optional dual-VT kiosk + gaming session (off by default)
  ];

  # GRUB + the custom Fallout theme + the verbose preDeviceCommands banner
  # (modules/branding.nix) are the single biggest boot-time cost on these
  # units. These boxes are wall-mounted dashboards nobody watches POST on —
  # drop the theme for a plain, fast GRUB menu instead.
  jupiter.branding.enable = lib.mkForce false;

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
  jupiter.dashboardGaming = {
    enable = false;
    # When enabled, Home Assistant auto-discovers a "Display Mode" select
    # (Dashboard/Gaming) and drives the active VT over MQTT, with live state.
    # Broker runs on lenovo (10.1.1.20); add a sops password + set
    # username/passwordFile once the broker requires auth.
    homeAssistant = {
      enable = true;
      broker = "10.1.1.20";
    };
  };
}
