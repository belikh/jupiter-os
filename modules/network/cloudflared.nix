{ config, ... }:

{
  # sopsFile defaults to sops.defaultSopsFile (set in modules/common.nix).
  sops.secrets.cloudflare_cert = { };

  services.cloudflared = {
    enable = true;
    tunnels = {
      "aa1088b8-a0e1-4073-8567-6a9bf5fb4bd7" = {
        credentialsFile = config.sops.secrets.cloudflare_cert.path;

        default = "http_status:404";
        ingress = {
          # Route headscale (for mesh clients)
          "headscale.jupiter.au" = "http://127.0.0.1:8080";
          # Route n8n
          "n8n.jupiter.au" = "http://127.0.0.1:5678";
          # Route Home Assistant
          "ha.jupiter.au" = "http://127.0.0.1:8123";
        };
      };
    };
  };
}
