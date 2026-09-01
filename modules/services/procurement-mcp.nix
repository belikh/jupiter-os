{ config, lib, pkgs, ... }:
let
  cfg = config.jupiter.services.procurementMcp;
in
{
  options.jupiter.services.procurementMcp = {
    enable = lib.mkEnableOption "federated procurement MCP server (Chinese + AU marketplaces, integration-only)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8787;
      description = "Local loopback port for streamable-HTTP transport (opencode connects via http://127.0.0.1:<port>/mcp).";
    };

    package = lib.mkOption {
      type = lib.types.package;
      # Shared with opencode's mcp.procurement stdio spawn (modules/core/
      # opencode.nix) so the two consumers can never drift or double the
      # closure. Rationale for the overrides lives in the package file.
      default = pkgs.callPackage ../../pkgs/procurement-python-env { };
      description = "Python env with the mcp SDK (server.py imports mcp.server.fastmcp) and the procurement deps.";
    };

    workingDir = lib.mkOption {
      type = lib.types.str;
      default = "/home/io/projects/procurement";
      description = "Checkout containing server.py (callisto local checkout).";
    };
  };

  config = lib.mkIf cfg.enable {
    # SOPS secrets — add via `sops secrets/secrets.yaml` (age keys in .sops.yaml, callisto included):
    # procurement_tmapi_token: ENC[...]        # ak_live_… from console.tmapi.io
    # procurement_sociavault_key: ENC[...]     # sk_live_… from sociavault.com
    # procurement_apify_token: ENC[...]        # apify_api_… from console.apify.com
    # procurement_database_url: ENC[...]       # postgresql://procurement:***@10.1.1.3:5432/jupiter
    # Optional: procurement_ebay_app_id, procurement_ebay_cert_id, procurement_aliexpress_*
    sops.secrets.procurement_tmapi_token = { sopsFile = ../../secrets/procurement.yaml; owner = "io"; group = "users"; mode = "0400"; };
    sops.secrets.procurement_sociavault_key = { sopsFile = ../../secrets/procurement.yaml; owner = "io"; group = "users"; mode = "0400"; };
    sops.secrets.procurement_apify_token = { sopsFile = ../../secrets/procurement.yaml; owner = "io"; group = "users"; mode = "0400"; };
    sops.secrets.procurement_database_url = { sopsFile = ../../secrets/procurement.yaml; owner = "io"; group = "users"; mode = "0400"; };
    # eBay app credentials + marketplace account deletion/closure compliance
    # token (the subscribe path that ENABLES a fresh production keyset).
    sops.secrets.procurement_ebay_deletion_token = { sopsFile = ../../secrets/procurement.yaml; owner = "io"; group = "users"; mode = "0400"; };

    systemd.services.procurement-mcp = {
      description = "Procurement MCP — federated search (callisto)";
      after = [ "network-online.target" "postgresql.service" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        # Behaviour — fleet Postgres on callisto per stack law
        PROCUREMENT_PG_SCHEMA = "procurement";
        PROCUREMENT_CACHE_TTL_S = "3600";
        PROCUREMENT_TIMEOUT_S = "8";
        CNY_TO_AUD = "0.215";
        # streamable-HTTP on loopback — the always-on service is reachable at
        # http://127.0.0.1:<port>/mcp for remote-type MCP clients; stdio under
        # systemd has no client, so the port is what makes the unit useful.
        MCP_HTTP_PORT = toString cfg.port;
      };
      # Load secrets as env vars via EnvironmentFile-style sops templates would be cleaner,
      # but for minimal module we expose them directly as files and let the wrapper read them.
      # The ExecStart wrapper cats each sops secret file into the expected env var.
      serviceConfig = {
        Type = "simple";
        User = "io";
        Group = "users";
        WorkingDirectory = cfg.workingDir;
        # Ensure PATH includes python + deps for `python server.py` without venv
        Environment = "PATH=${cfg.package}/bin:/run/current-system/sw/bin";
        ExecStart = pkgs.writeShellScript "procurement-mcp-start" ''
          set -euo pipefail
          export TMAPI_TOKEN="$(cat ${config.sops.secrets.procurement_tmapi_token.path})"
          export SOCIAVAULT_API_KEY="$(cat ${config.sops.secrets.procurement_sociavault_key.path})"
          export APIFY_TOKEN="$(cat ${config.sops.secrets.procurement_apify_token.path})"
          export DATABASE_URL="$(cat ${config.sops.secrets.procurement_database_url.path})"
          # eBay compliance: the /ebay/notifications routes hash the token, so
          # it must be in the environment; the endpoint URL must byte-match
          # what's registered in the eBay developer portal.
          export EBAY_DELETION_TOKEN="$(cat ${config.sops.secrets.procurement_ebay_deletion_token.path})"
          export EBAY_DELETION_ENDPOINT="https://procurement.jupiter.au/ebay/notifications"
          # Optional keys — only export if the sops file exists (owner may not have provisioned yet)
          for k in procurement_ebay_app_id procurement_ebay_cert_id procurement_aliexpress_app_key procurement_aliexpress_app_secret; do
            f="/run/secrets/$k"
            if [ -f "$f" ]; then
              case "$k" in
                procurement_ebay_app_id) export EBAY_APP_ID="$(cat $f)" ;;
                procurement_ebay_cert_id) export EBAY_CERT_ID="$(cat $f)" ;;
                procurement_aliexpress_app_key) export ALIEXPRESS_APP_KEY="$(cat $f)" ;;
                procurement_aliexpress_app_secret) export ALIEXPRESS_APP_SECRET="$(cat $f)" ;;
              esac
            fi
          done
          exec ${cfg.package}/bin/python ${cfg.workingDir}/server.py
        '';
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    # Reverse-proxy note — procurement-mcp is loopback-only (127.0.0.1:${toString cfg.port}).
    # opencode connects via remote URL, not via the Cloudflare tunnel, so no ingress rule is added.
    # To expose publicly, add a callisto cloudflare tunnel ingress similar to opencode-web/dsh.
  };
}
