{
  config,
  pkgs,
  lib,
  ...
}:

# Shared Cage (Wayland) + Chromium kiosk wiring for the TCx Wave dashboard
# fleet. Each unit is its own host (own hostName/hostId/dashboard URL — they
# can't share an identity since they each point at a different room's Home
# Assistant dashboard), but the kiosk session itself is identical hardware
# and identical mechanics, so it lives here once.

let
  cfg = config.jupiter.dashboardKiosk;

  # The extra flags are power/perf, not behavioural: native Wayland (no
  # XWayland probing), VA-API hardware video decode on the HD 520 iGPU
  # (offloads the CPU), and trimming background networking/sync/updates
  # that would otherwise wake the box for no benefit on a single-purpose
  # kiosk.
  chromiumFlags = [
    "--kiosk"
    "--app=${cfg.url}"
    "--ozone-platform=wayland"
    "--use-gl=egl"
    "--enable-features=VaapiVideoDecoder,VaapiIgnoreDriverChecks"
    "--disable-background-networking"
    "--disable-sync"
    "--disable-translate"
    "--disable-component-update"
    "--disable-extensions"
    "--no-first-run"
    "--remote-debugging-port=9222"
    "--remote-allow-origins=*"
  ];

  # cage-tty1 is ordered only against the display/session stack, NOT
  # networking, so it launches chromium the moment the compositor is up.
  # On the wireless kiosk (thebe) that races wpa_supplicant association:
  # the dashboard URL is requested before the adapter has a carrier, so
  # the first load times out at a "no internet" error page and cage never
  # re-issues it. Block here until a default route exists (interface-
  # agnostic — works for both wlan0 and predictable wlp* naming) before
  # exec'ing chromium. The wait is a no-op on the wired kiosks, which have
  # a route within ~1s of boot. Falls through after the timeout so a
  # permanently-offline box still shows chromium's error page rather than
  # a black screen.
  kioskLaunch = pkgs.writeShellScript "kiosk-launch" ''
    for _ in $(seq 1 30); do
      if [ -n "$(${pkgs.iproute2}/bin/ip route show default 2>/dev/null)" ]; then
        break
      fi
      sleep 1
    done
    exec ${pkgs.chromium}/bin/chromium ${lib.concatStringsSep " " chromiumFlags}
  '';
in
{
  options.jupiter.dashboardKiosk = {
    enable = lib.mkEnableOption "TCx Wave Cage + Chromium kiosk session";

    url = lib.mkOption {
      type = lib.types.str;
      description = "Home Assistant dashboard URL this unit displays full-screen.";
      example = "https://iot.jupiter.au/main-floor/main";
    };
  };

  config = lib.mkIf cfg.enable {
    services.xserver.enable = false; # Wayland is lighter and faster for kiosks

    services.cage = {
      enable = true;
      user = "kiosk";
      program = "${kioskLaunch}";
    };

    users.users.kiosk = {
      isNormalUser = true;
      # "render" grants access to /dev/dri/renderD* for VA-API hardware decode.
      extraGroups = [
        "video"
        "render"
      ];
    };
  };
}
