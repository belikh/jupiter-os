{
  config,
  lib,
  pkgs,
  ...
}:

# A screensaver for the bare Linux virtual console — Matrix-style "cmatrix"
# rain, running continuously on tty1. europa is a headless NAS that normally
# has no monitor attached; this is purely for the moments a display gets
# plugged in (or a crash cart rolled up), so the box looks alive and
# unmistakably cool instead of sitting at a static login prompt.
#
# The service disables getty on the target VT and owns it exclusively
# (TTYVHangup is deliberately OFF — it would SIGHUP the very process we
# start). A login shell remains one keystroke away on any other tty
# (Ctrl+Alt+F2); getty elsewhere is untouched.

let
  cfg = config.jupiter.consoleScreensaver;
in
{
  options.jupiter.consoleScreensaver = {
    enable = lib.mkEnableOption "a Matrix-style cmatrix screensaver on the console";

    package = lib.mkPackageOption pkgs "cmatrix" { };

    tty = lib.mkOption {
      type = lib.types.ints.u8;
      default = 1;
      description = ''
        Virtual console (ttyN) to display the screensaver on. Defaults to 1
        so it shows on the primary VT the firmware hands off to.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    # Free the VT from getty so cmatrix owns it exclusively. Otherwise getty
    # and cmatrix both hold /dev/ttyN open, cmatrix's stdin reads EOF, and it
    # exits immediately. A login shell stays available on any other tty.
    systemd.services."getty@tty${toString cfg.tty}".enable = lib.mkForce false;

    systemd.services.console-screensaver = {
      description = "cmatrix console screensaver on tty${toString cfg.tty}";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-logind.service" ];

      # ncurses needs to know it's on the Linux VT, not a generic terminal.
      environment.TERM = "linux";

      serviceConfig = {
        # idle: don't start until other jobs have settled, so boot messages
        # don't interleave with the screensaver.
        Type = "idle";
        StandardInput = "tty";
        StandardOutput = "tty";
        TTYPath = "/dev/tty${toString cfg.tty}";
        TTYReset = true;
        # Do NOT vhangup the tty on start — that SIGHUPs the very process we
        # just launched. We've cleared getty above instead.
        TTYVHangup = false;
        # -b  bold (brighter glyphs against the black VT background).
        # Run continuously; to log in, switch to another tty (Ctrl+Alt+F2).
        ExecStart = "${lib.getExe cfg.package} -b";
        Restart = "always";
        RestartSec = "3";
      };
    };
  };
}
