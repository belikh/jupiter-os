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
      packages = [ pkgs.terminus_font ];
      font = "ter-132n";
      colors = [
        "001100" # Black (Background)
        "1aff1a" # Red -> Green
        "1aff1a" # Green
        "1aff1a" # Yellow -> Green
        "1aff1a" # Blue -> Green
        "1aff1a" # Magenta -> Green
        "1aff1a" # Cyan -> Green
        "1aff1a" # White -> Green
        "001100" # Bright Black
        "1aff1a" # Bright Red -> Green
        "1aff1a" # Bright Green
        "1aff1a" # Bright Yellow -> Green
        "1aff1a" # Bright Blue -> Green
        "1aff1a" # Bright Magenta -> Green
        "1aff1a" # Bright Cyan -> Green
        "1aff1a" # Bright White -> Green
      ];
    };

    # 2. Bootloader and Kernel Messages
    boot = {
      initrd.verbose = true;
      consoleLogLevel = 7;
      kernelParams = [
        "vt.default_utf8=1"
        "fbcon=nodefer"
        "vt.global_cursor_default=0" # Solid block cursor
      ];

      # Inject RobCo ASCII banner right as initrd starts
      initrd.systemd.services.robco-banner = {
        description = "RobCo Industries Boot Banner";
        wantedBy = [ "sysinit.target" ];
        before = [ "sysinit.target" ];
        serviceConfig = {
          Type = "oneshot";
          StandardOutput = "tty";
          StandardError = "tty";
          DefaultDependencies = false;
        };
        script = ''
          echo -e "\e[1;32m"
          echo "╔══════════════════════════════════════════════════════════════════════╗"
          echo "║                                                                      ║"
          echo "║                      J U P I T E R    O S                            ║"
          echo "║                 RobCo Industries Unified System                      ║"
          echo "║                 COPYRIGHT 2075-2077 ROBCO INDUSTRIES                 ║"
          echo "║                 CORE VERSION 4.02.08.00                              ║"
          echo "║                                                                      ║"
          echo "╚══════════════════════════════════════════════════════════════════════╝"
          echo -e "\e[0;32m"
        '';
      };
    };

    # 2. Terminal Greeter (Login Screen)
    # Replaces GDM/SDDM with a retro text-based interface (tuigreet) to launch Niri
    services.greetd = mkIf config.jupiter.desktop.enable {
      enable = true;
      settings = {
        default_session = {
          command = "${pkgs.tuigreet}/bin/tuigreet --time --asterisks --greeting 'ROBCO INDUSTRIES UNIFIED OPERATING SYSTEM - JUPITER OS' --theme 'border=green;text=green;prompt=green;time=green;action=green;button=green;container=black;input=green' --cmd niri-session";
          user = "greeter";
        };
      };
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
