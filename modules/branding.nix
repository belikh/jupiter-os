{ config, pkgs, lib, ... }:

with lib;
let
  cfg = config.jupiter.branding;
in
{
  options.jupiter.branding = {
    enable = mkEnableOption "Enable Jupiter OS / RobCo Pip-Boy branding (MOTD, boot, login)";
  };

  config = mkIf cfg.enable {

    # 1. TTY & Console Aesthetic
    # Force the kernel to use a green-on-black color scheme during boot and in TTYs.
    console = {
      enable = true;
      earlySetup = true;
      colors = [
        "001100" # Black (Background)
        "1aff1a" # Red -> Green
        "1aff1a" # Green
        "ffb642" # Yellow -> Amber
        "1aff1a" # Blue -> Green
        "1aff1a" # Magenta -> Green
        "1aff1a" # Cyan -> Green
        "1aff1a" # White -> Green
        "002200" # Bright Black
        "1aff1a" # Bright Red -> Green
        "1aff1a" # Bright Green
        "ffb642" # Bright Yellow -> Amber
        "1aff1a" # Bright Blue -> Green
        "1aff1a" # Bright Magenta -> Green
        "1aff1a" # Bright Cyan -> Green
        "1aff1a" # Bright White -> Green
      ];
    };

    # Make the boot sequence verbose like a retro mainframe, disabling graphical splashes
    boot.initrd.verbose = true;
    boot.consoleLogLevel = 7;
    boot.kernelParams = [ 
      "console=tty1"
      "loglevel=7"
      "fbcon=nodefer"
      "vt.global_cursor_default=0" # block cursor
    ];

    # 2. Terminal Greeter (Login Screen)
    # Replaces GDM/SDDM with a retro text-based interface (tuigreet) to launch Niri
    services.greetd = mkIf config.jupiter.desktop.enable {
      enable = true;
      settings = {
        default_session = {
          command = ''
            ${pkgs.greetd.tuigreet}/bin/tuigreet \
              --time \
              --asterisks \
              --greeting "ROBCO INDUSTRIES UNIFIED OPERATING SYSTEM - JUPITER OS" \
              --theme "border=green;text=green;prompt=green;time=green;action=green;button=green;container=black;input=green" \
              --cmd niri-session
          '';
          user = "greeter";
        };
      };
    };

    # Fix systemd issues with greetd
    systemd.services.greetd.serviceConfig = {
      Type = "idle";
      StandardInput = "tty";
      StandardOutput = "tty";
      StandardError = "journal"; # Without this, errors spam the console
      TTYReset = true;
      TTYVHangup = true;
      TTYVTDisallocate = true;
    };

    # 3. Message of the Day (MOTD)
    users.motd = ''
       ========================================================================
       ||                                                                    ||
       ||                      J U P I T E R    O S                          ||
       ||                 RobCo Industries Unified System                    ||
       ||                                                                    ||
       ========================================================================
       
       Welcome to the Jupiter mainframe.
       Unauthorized access will be logged and may result in vaporization.
       
       Connection established.
       Waiting for input...
    '';
  };
}
