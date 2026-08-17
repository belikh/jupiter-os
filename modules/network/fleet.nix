{
  config,
  lib,
  ...
}:

# Fleet topology — the single source of truth for cross-host addresses.
#
# Before this module the fleet's IPs were hardcoded ~40 times across 21 files
# (23x callisto's 10.1.1.3, 17x europa's 10.1.1.2), held together only by
# comments. Every consumer below reads them from here instead, so a future
# reservation change is a one-line edit.
#
# NOTE (import invariant): option defaults in OTHER modules reference
# config.jupiter.fleet.addresses.*, so any host importing one of those modules
# must also import this one. It is imported fleet-wide via modules/common.nix,
# and every consumer module is imported only by hosts that import common.nix
# (pallene imports neither). Keep it that way when adding consumers.
#
# Addresses are UniFi DHCP reservations, not DNS: the fleet has no resolver
# yet (ganymede's future role), which is exactly why the literals exist.
{
  options.jupiter.fleet = {
    addresses = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      description = "Static per-host LAN addresses (UniFi DHCP reservations).";
    };

    lanCidr = lib.mkOption {
      type = lib.types.str;
      default = "10.1.1.0/24";
      description = "The trusted home LAN segment (firewall scoping, NFS exports).";
    };
  };

  config.jupiter.fleet.addresses = {
    gateway = "10.1.1.1"; # the UniFi gateway (also the LAN resolver)
    europa = "10.1.1.2"; # NAS + data hub + Harmonia + PXE
    callisto = "10.1.1.3"; # shared builder + MQTT broker (MAC c4:65:16:b8:76:03)
    homeassistant = "10.1.1.72"; # the HA box (not a NixOS fleet member)
  };
}
