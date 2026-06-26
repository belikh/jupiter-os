{ config, pkgs, ... }:

{
  # We will define the cloudflared token inside secrets.yaml later
  # sops.secrets.cloudflared_token = {
  #   sopsFile = ../secrets/secrets.yaml;
  # };

  services.cloudflared = {
    enable = true;
    tunnels = {
      "aa1088b8-a0e1-4073-8567-6a9bf5fb4bd7" = {
        # The path to the credentials JSON file
        # credentialsFile = config.sops.secrets.cloudflared_token.path;
        credentialsFile = "/var/lib/cloudflared/cert.json";
        
        default = "http_status:404";
        ingress = {
          # Route headscale (for mesh clients)
          "headscale.jupiter.au" = "http://127.0.0.1:8080";
          # Route n8n
          "n8n.jupiter.au" = "http://127.0.0.1:5678";
        };
      };
    };
  };
}
