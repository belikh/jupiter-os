{ config, lib, ... }:

let
  cfg = config.jupiter.services.n8n;
in
{
  options.jupiter.services.n8n.database = {
    enable = lib.mkEnableOption "back n8n with PostgreSQL instead of the bundled SQLite";

    host = lib.mkOption {
      type = lib.types.str;
      example = "callisto.home.jupiter.au";
      description = "PostgreSQL host n8n connects to.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5432;
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "n8n";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "n8n";
    };

    passwordFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to the DB password (a sops secret readable by the n8n user). Passed
        to n8n via DB_POSTGRESDB_PASSWORD_FILE, so it's never in the Nix store.
      '';
    };
  };

  config = {
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
      }
      // lib.optionalAttrs cfg.database.enable {
        DB_TYPE = "postgresdb";
        DB_POSTGRESDB_HOST = cfg.database.host;
        DB_POSTGRESDB_PORT = toString cfg.database.port;
        DB_POSTGRESDB_DATABASE = cfg.database.name;
        DB_POSTGRESDB_USER = cfg.database.user;
        # n8n honours the _FILE suffix and reads the password from this path.
        DB_POSTGRESDB_PASSWORD_FILE = toString cfg.database.passwordFile;
      };

      # Optional: load extra environment variables (e.g. SMTP / external API
      # credentials) for n8n. n8n runs fine without this. To enable, add an
      # `n8n_env` entry to secrets/secrets.yaml, declare the sops secret, and
      # uncomment the line below:
      #   environmentFile = config.sops.secrets.n8n_env.path;
    };
  };
}
