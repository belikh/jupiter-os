{ config, pkgs, ... }:

{
  services.n8n = {
    enable = true;
    openFirewall = true; # Allow local mesh access if needed
    
    settings = {
      N8N_HOST = "127.0.0.1"; # Listens on localhost for Cloudflare Tunnel
      N8N_PORT = 5678;
      N8N_PROTOCOL = "http";
      WEBHOOK_URL = "https://n8n.jupiter.au";
      GENERIC_TIMEZONE = "Australia/Brisbane";
      # You can add the database settings here (postgres is recommended for prod)
      # DB_TYPE = "postgresdb";
    };

    # Automatically load environment variables for credentials
    # environmentFile = config.sops.secrets.n8n_env.path;
  };
}
