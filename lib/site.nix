# Canonical network facts for the home site — the single source of truth for
# VLANs, subnets, the resolver address, and the internal DNS records.
#
# Consumed by BOTH:
#   * the NixOS resolver config (hosts/lenovo -> jupiter.dns), and
#   * the terranix UniFi stack (terraform/unifi/default.nix),
# so the two can never drift. This is plain data (no module system), which is
# why both a NixOS module and a terranix module can `import` it directly.
#
# Verified against the live UDM Pro: Cameras = VLAN 2 / 192.168.3.0/24,
# IOT = VLAN 3 / 192.168.2.0/24.
{
  # The single internal resolver every client (and DHCP) points at.
  resolver = "10.1.1.20";
  gateway = "10.1.1.1";
  domain = "home.jupiter.au";

  # L2/L3 networks. `networkCidr` is the network address (for DNS access-control
  # / allow-lists); `gatewayCidr` is the gateway address with prefix (what the
  # UniFi `unifi_network.subnet` field actually wants). vlan = null is untagged.
  networks = {
    default = {
      name = "Default";
      vlan = null;
      networkCidr = "10.1.1.0/24";
      gatewayCidr = "10.1.1.1/24";
      dhcpStart = "10.1.1.6";
      dhcpStop = "10.1.1.254";
    };
    cameras = {
      name = "Cameras";
      vlan = 2;
      networkCidr = "192.168.3.0/24";
      gatewayCidr = "192.168.3.1/24";
      dhcpStart = "192.168.3.6";
      dhcpStop = "192.168.3.254";
    };
    iot = {
      name = "IOT";
      vlan = 3;
      networkCidr = "192.168.2.0/24";
      gatewayCidr = "192.168.2.1/24";
      dhcpStart = "192.168.2.6";
      dhcpStop = "192.168.2.254";
    };
  };

  # headscale mesh ranges — also permitted to query the resolver.
  meshCidrs = [
    "100.64.0.0/10"
    "fd7a:115c:a1e0::/48"
  ];

  # Static internal A/PTR records for the split-horizon zone.
  records = {
    "gateway.home.jupiter.au" = "10.1.1.1";
    "nas.home.jupiter.au" = "10.1.1.2";
    "lenovo.home.jupiter.au" = "10.1.1.20";
    "ha.home.jupiter.au" = "10.1.1.72";
    "smokeping.home.jupiter.au" = "10.1.1.221";
  };
}
