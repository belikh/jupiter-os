{
  config,
  lib,
  ...
}:

# Shared game-controller stack — the exact wiring modules/gaming/console.nix
# (kiosk gaming mode) and modules/desktop/arcade-console.nix (boot-to-arcade
# appliances) both need: Xbox pads over Bluetooth (xpadneo), the official
# dongle/wired path (xone), Bluetooth brought up unattended so a trusted
# paired controller can reconnect at boot, and the udev rule that stops
# DualSense/DualShock touchpads firing phantom mouse clicks mid-game.
#
# Before this module both files carried byte-identical copies; because
# services.udev.extraRules is types.lines, the duplicated rules landed TWICE
# in the udev file on hosts importing both, and a future value divergence
# between the copies would have turned a merge into a hard eval conflict.
{
  options.jupiter.gaming.controllers = {
    enable = lib.mkEnableOption "game controller stack (xpadneo, xone, Bluetooth, DualSense touchpad udev quirk)";
  };

  config = lib.mkIf config.jupiter.gaming.controllers.enable {
    hardware.xpadneo.enable = lib.mkDefault true;
    hardware.xone.enable = lib.mkDefault true;

    # powerOnBoot: bring hci0 up unattended so a trusted (paired) controller
    # can auto-reconnect by pad-initiated advertising the moment the box
    # boots — without it the DS4 sat paired-but-unreachable until someone
    # powered the adapter by hand (observed live on callisto).
    hardware.bluetooth = {
      enable = lib.mkDefault true;
      powerOnBoot = lib.mkDefault true;
    };

    services.udev.extraRules = ''
      ATTRS{name}=="Sony Interactive Entertainment Wireless Controller Touchpad", ENV{LIBINPUT_IGNORE_DEVICE}="1"
      ATTRS{name}=="Sony Interactive Entertainment DualSense Wireless Controller Touchpad", ENV{LIBINPUT_IGNORE_DEVICE}="1"
      ATTRS{name}=="Wireless Controller Touchpad", ENV{LIBINPUT_IGNORE_DEVICE}="1"
      ATTRS{name}=="DualSense Wireless Controller Touchpad", ENV{LIBINPUT_IGNORE_DEVICE}="1"
    '';
  };
}
