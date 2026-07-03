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
in
{
  options.jupiter.dashboardKiosk = {
    enable = lib.mkEnableOption "TCx Wave Cage + Chromium kiosk session";

    url = lib.mkOption {
      type = lib.types.str;
      description = "Home Assistant dashboard URL this unit displays full-screen.";
      example = "https://ha.jupiter.au/kitchen";
    };
  };

  config = lib.mkIf cfg.enable {
    services.xserver.enable = false; # Wayland is lighter and faster for kiosks

    services.cage = {
      enable = true;
      user = "kiosk";
      # The extra flags are power/perf, not behavioural: native Wayland (no
      # XWayland probing), VA-API hardware video decode on the HD 520 iGPU
      # (offloads the CPU), and trimming background networking/sync/updates
      # that would otherwise wake the box for no benefit on a single-purpose
      # kiosk.
      program = "${pkgs.chromium}/bin/chromium --kiosk --incognito --app=${cfg.url} --ozone-platform=wayland --use-gl=egl --enable-features=VaapiVideoDecoder,VaapiIgnoreDriverChecks --disable-background-networking --disable-sync --disable-translate --disable-component-update --disable-extensions --no-first-run";
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
