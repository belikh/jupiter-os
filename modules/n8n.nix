{ config, pkgs, ... }:

{
  # n8n uses the 'sustainableUse' license which is considered unfree by Nixpkgs
  nixpkgs.config.allowUnfree = true;

  services.n8n = {
    enable = true;
    openFirewall = true; # Allow local mesh access if needed

    environment = {
      N8N_HOST = "127.0.0.1"; # Listens on localhost for Cloudflare Tunnel
      N8N_PORT = "5678";
      N8N_PROTOCOL = "http";
      WEBHOOK_URL = "https://n8n.jupiter.au";
      GENERIC_TIMEZONE = "Australia/Brisbane";
    };

    # Optional: load extra environment variables (e.g. SMTP / external API
    # credentials) for n8n. n8n runs fine without this. To enable, add an
    # `n8n_env` entry to secrets/secrets.yaml, declare the sops secret, and
    # uncomment the line below:
    #   environmentFile = config.sops.secrets.n8n_env.path;
  };
}
