{ config, lib, pkgs, ... }:

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
    api_url = "https://10.1.1.1"; # UDM Pro IP
    allow_insecure = true;
  };

  resource.unifi_network = {
    default = {
      name = "Default";
      purpose = "corporate";
      subnet = "10.1.1.1/24";
      dhcp_start = "10.1.1.6";
      dhcp_stop = "10.1.1.254";
      dhcp_dns = ["10.1.1.20"];
      dhcp_enabled = true;
    };
    cameras = {
      name = "Cameras";
      purpose = "corporate";
      vlan_id = 2;
      subnet = "10.1.2.1/24";
      dhcp_start = "10.1.2.6";
      dhcp_stop = "10.1.2.254";
      dhcp_dns = ["10.1.1.20"];
      dhcp_enabled = true;
    };
    iot = {
      name = "IOT";
      purpose = "corporate";
      vlan_id = 3;
      subnet = "10.1.3.1/24";
      dhcp_start = "10.1.3.6";
      dhcp_stop = "10.1.3.254";
      dhcp_dns = ["10.1.1.20"];
      dhcp_enabled = true;
    };
  };

  resource.unifi_firewall_group = {
    dns_ports = {
      name = "dns-ports";
      type = "port-group";
      members = ["53" "853"];
    };
    dns_resolvers = {
      name = "dns-resolvers";
      type = "address-group";
      members = ["10.1.1.20"];
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
