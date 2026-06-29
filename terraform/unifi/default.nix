{ lib, ... }:

let
  # Single source of truth for VLANs/subnets/resolver — shared with the NixOS
  # DNS config so the two never drift. See lib/site.nix.
  site = import ../../lib/site.nix;

  mkNetwork =
    _: net:
    {
      name = net.name;
      purpose = "corporate";
      subnet = net.gatewayCidr;
      dhcp_start = net.dhcpStart;
      dhcp_stop = net.dhcpStop;
      dhcp_dns = [ site.resolver ];
      dhcp_enabled = true;
    }
    // lib.optionalAttrs (net.vlan != null) { vlan_id = net.vlan; };
in
{
  terraform = {
    required_providers = {
      unifi = {
        source = "paultyng/unifi";
        version = "~> 0.41.0";
      };
    };
  };

  variable = {
    unifi_password = {
      type = "string";
      sensitive = true;
    };
  };

  provider.unifi = {
    username = "admin";
    password = "\${var.unifi_password}";
    api_url = "https://${site.gateway}"; # UDM Pro
    allow_insecure = true;
  };

  # Networks generated from lib/site.nix (keys: default, cameras, iot).
  resource.unifi_network = lib.mapAttrs mkNetwork site.networks;

  resource.unifi_firewall_group = {
    dns_ports = {
      name = "dns-ports";
      type = "port-group";
      members = [
        "53"
        "853"
      ];
    };
    dns_resolvers = {
      name = "dns-resolvers";
      type = "address-group";
      members = [ site.resolver ];
    };
  };

  resource.unifi_firewall_rule = {
    allow_resolver_dns = {
      name = "Allow Local Resolver DNS Out";
      action = "accept";
      ruleset = "LAN_OUT";
      rule_index = 2000;
      protocol = "tcp_udp";
      src_address = "\${unifi_firewall_group.dns_resolvers.id}";
      dst_port = "\${unifi_firewall_group.dns_ports.id}";
    };
    block_all_other_dns = {
      name = "Block Rogue DNS Out";
      action = "drop";
      ruleset = "LAN_OUT";
      rule_index = 2001;
      protocol = "tcp_udp";
      dst_port = "\${unifi_firewall_group.dns_ports.id}";
    };
  };
}
