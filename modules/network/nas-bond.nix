{ config, lib, ... }:

with lib;
let
  cfg = config.jupiter.nas.bond;
in
{
  options.jupiter.nas.bond = {
    enable = mkEnableOption ''
      802.3ad (LACP) link aggregation across the two BCM5720 1GbE ports.
      ⚠️  Enable the matching port-aggregation/LACP on the UniFi switch FIRST,
      or the NAS will lose network connectivity.
    '';
    interfaces = mkOption {
      type = types.listOf types.str;
      default = [ "enp2s0f0" "enp2s0f1" ];
      description = "The two physical NICs to aggregate.";
    };
    mtu = mkOption {
      type = types.int;
      default = 1500;
      description = "Set to 9000 for jumbo frames (only if switch + clients agree).";
    };
  };

  config = mkIf cfg.enable {
    networking.useDHCP = false;

    networking.bonds.bond0 = {
      interfaces = cfg.interfaces;
      driverOptions = {
        mode = "802.3ad";
        lacp_rate = "fast";
        xmit_hash_policy = "layer3+4"; # spread streams across both links
        miimon = "100";
      };
    };

    networking.interfaces.bond0 = {
      useDHCP = true;
      mtu = cfg.mtu;
    };
  };
}
