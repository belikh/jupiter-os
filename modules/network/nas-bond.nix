{ config, lib, ... }:

# Optional 2×1GbE LACP bond for the MicroServer Gen10's dual BCM5720 NICs.
# Disabled by default — requires the UniFi switch-side LACP to be configured
# first. When enabled, the static IP (10.1.1.2) moves onto bond0.

let
  cfg = config.jupiter.nas.bond;
in
{
  options.jupiter.nas.bond = {
    enable = lib.mkEnableOption "LACP bonding of the two 1GbE NICs";

    interfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "enp2s0f0"
        "enp2s0f1"
      ];
      description = "The two NICs to bond (both BCM5720 ports on the MicroServer).";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.bonds.bond0 = {
      interfaces = cfg.interfaces;
      driverOptions = {
        mode = "802.3ad"; # LACP
        miimon = "100";
        lacp_rate = "fast";
        xmit_hash_policy = "layer3+4";
      };
    };

    networking.interfaces.bond0.ipv4.addresses = [
      {
        address = "10.1.1.2";
        prefixLength = 24;
      }
    ];
  };
}
