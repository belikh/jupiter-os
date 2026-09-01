{
  config,
  lib,
  pkgs,
  ...
}:

# Model Router — self-hosted OpenAI-compatible endpoint pooling free LLM
# inference tiers (OpenRouter, Groq, NVIDIA NIM, Cloudflare Workers AI,
# Z.ai, Ollama Cloud, ... 41 providers in the signed seed), with a learned
# quota ledger + reset scheduling, per-endpoint health states carrying
# reasons, catalogue-rotation discovery, an AES-256-GCM credential vault
# and a Zeus-styled dashboard.
#
# Public reachability is callisto's dedicated Cloudflare Tunnel
# (router.jupiter.au → loopback :8080, ingress added in the host config
# next to dsh/opencode/design). Provider keys bootstrap from the sops
# secret (dsh_env-style shape) into the router's own encrypted vault on
# first boot; the dashboard is the source of truth afterwards.
#
# Upstream (private): https://github.com/belikh/model-router — the Go
# source is vendored at pkgs/model-router (ADR-0002 D2: the private repo
# can't be a flake input the builders can fetch); this module IS the
# upstream nix/model-router.nix with the package default pointed at the
# in-tree derivation.
let
  cfg = config.jupiter.services.modelRouter;
in
{
  options.jupiter.services.modelRouter = {
    enable = lib.mkEnableOption "model-router (free-tier LLM pooling gateway)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../pkgs/model-router { };
      description = "The model-router package to run (vendored in-tree).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Local loopback port the router listens on (the tunnel proxies to it).";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/model-router";
      description = ''
        Directory holding the router's state: config.json (client token),
        router.db (WAL-mode SQLite) and master.key (vault key, 0600).
      '';
    };

    envFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to an environment file holding provider API keys for the
        first-boot vault bootstrap (GROQ_API_KEY, Z_AI_API_KEY,
        OPENCODE_API_KEY, TOKENROUTER_API_KEY, ... — any seed env_key).
        Wire a sops secret here, e.g. config.sops.secrets.model_router_env.path.
        The router copies keys into its encrypted vault and validates them
        with a one-probe check; after first boot the dashboard owns them.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the port in the firewall for LAN access (tunnel access needs no firewall).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Dedicated system user (fleet pattern, mirrors dsh): the sops env secret
    # is group "users" 0440, so the router user joins that group to read it
    # at bootstrap. Not DynamicUser: dynamic UIDs can't hold group
    # memberships stably, and the vault state persists across boots.
    users.users.model-router = {
      isSystemUser = true;
      group = "model-router";
      home = cfg.dataDir;
      createHome = true;
      extraGroups = [ "users" ]; # read dsh_env (0440 users) for bootstrap
    };
    users.groups.model-router = { };

    systemd.services.model-router = {
      description = "model-router: free-tier LLM pooling gateway (OpenAI-compatible)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "exec";
        ExecStart = "${cfg.package}/bin/router";
        User = "model-router";
        Group = "model-router";
        Environment = [
          "MODEL_ROUTER_DATA_DIR=${cfg.dataDir}"
          "MODEL_ROUTER_LISTEN_ADDR=127.0.0.1:${toString cfg.port}"
        ];
        EnvironmentFile = lib.mkIf (cfg.envFile != null) [ cfg.envFile ];
        WorkingDirectory = cfg.dataDir;
        Restart = "on-failure";
        RestartSec = "5s";

        # hardening: the router needs no privileges at all
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        SystemCallFilter = [ "@system-service" "~@privileged" ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        CapabilityBoundingSet = [ "" ];
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
