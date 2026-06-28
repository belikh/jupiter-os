{ config, pkgs, ... }:

{
  imports = [
    ../../modules/common-stateful.nix
    ./disko.nix # OS disk layout (destructive — confirm device before install)
    ../../modules/services/tcxwave-power-tuning.nix # kernel/GPU/storage/power tuning for the i5-6500U + HD 520 hardware
  ];

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
}
