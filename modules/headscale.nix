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
          # Mesh clients use OUR resolver too -> their DNS egresses anonymized
          # through home, and they resolve internal home.jupiter.au names.
          global = [
            "10.1.1.20"
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
