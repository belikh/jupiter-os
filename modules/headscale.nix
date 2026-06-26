{ config, pkgs, ... }:

{
  services.headscale = {
    enable = true;
    port = 8080;
    settings = {
      server_url = "https://headscale.jupiter.au"; # Exposed via Cloudflare
      dns = {
        magic_dns = true;
        base_domain = "jupiter.mesh";
        nameservers = {
          global = [
            "1.1.1.1"
            "1.0.0.1"
          ];
        };
      };
      ip_prefixes = [
        "100.64.0.0/10"
        "fd7a:115c:a1e0::/48"
      ];
    };
  };

  # Ensure the firewall allows the local proxy
  networking.firewall.allowedTCPPorts = [ 8080 ];
}
