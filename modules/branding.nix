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
    # =========================================================================
    # 1. THE BOOTLOADER: ROBCO INDUSTRIES UNIFIED OPERATING SYSTEM MENU
    # =========================================================================
    boot.loader.grub = {
      enable = true;
      # Points directly to the master fallout theme repository
      theme = pkgs.fetchFromGitHub {
        owner = "shvchk";
        repo = "fallout-grub-theme";
        rev = "fcc680d166fa2a723365004df4b8736359d15a62";
        sha256 = "sha256-7kvLfD6Nz4cEMrmCA9yq4enyqVyqiTkVZV5y4RyUatU=";
      };
      # Keeps it looking like an old-school black terminal screen
      backgroundColor = "#000000";
      splashImage = null;
      device = "nodev"; # Required for GRUB on EFI/VM
      efiSupport = true;
    };
    
    # We must disable systemd-boot if we are explicitly enabling grub for EFI
    boot.loader.systemd-boot.enable = lib.mkForce false;

    # =========================================================================
    # 2. THE KERNEL STAGE: VERBOSE DIAGNOSTICS & SYSTEMD INITIALIZATION
    # =========================================================================
    boot.consoleLogLevel = 4;
    boot.initrd.verbose = true;
    boot.kernelParams = [
      "vt.default_utf8=1"
    ];

    # Inject an authentic RobCo Bios Header into the initial RAM disk stage
    # (Note: we disable systemd in initrd for this to work natively)
    boot.initrd.systemd.enable = false;
    boot.initrd.preDeviceCommands = ''
      echo -e "\e[1;32m"
      echo "=========================================================="
      echo "  ROBCO INDUSTRIES UNIFIED OPERATING SYSTEM               "
      echo "  COPYRIGHT 2075-2077 ROBCO INDUSTRIES                    "
      echo "  CORE VERSION 4.02.08.00                                 "
      echo "                                                          "
      echo "  LOADING BASE ATTACHMENTS...                             "
      echo "=========================================================="
      echo -e "\e[0;32m"
    '';

    # =========================================================================
    # 3. THE TEXT ENVIRONMENT: GREEN PHOSPHOR MATRIX MONOCHROME COLORWAY
    # =========================================================================
    console = {
      enable = true;
      earlySetup = true;
      font = "Lat2-Terminus16";
      # Force the 16 base TTY color slots into strict dark/bright green shades
      colors = [
        "000000" "00aa00" "00aa00" "00aa00" "00aa00" "00aa00" "00aa00" "aaaaaa"
        "555555" "55ff55" "55ff55" "55ff55" "55ff55" "55ff55" "55ff55" "ffffff"
      ];
    };

    # =========================================================================
    # 4. POST-BOOT DISPLAY: LY TEXT-BASED TTY MATRIX DISPLAY MANAGER
    # =========================================================================
    services.displayManager.ly = mkIf config.jupiter.desktop.enable {
      enable = true;
    };

    # Disable greetd since we are using ly
    services.greetd.enable = lib.mkForce false;

    # Message of the Day (MOTD)
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
