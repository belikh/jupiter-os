{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.jupiter.services.headscale;
in
{
  options.jupiter.services.headscale = {
    enable = lib.mkEnableOption "Headscale control plane server (self-hosted Tailscale)";

    # Server configuration
    serverUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://headscale.jupiter.au";
      description = "Public URL of the Headscale server (for clients to connect).";
    };

    listenAddr = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0:8080";
      description = "Address:port for Headscale HTTP server.";
    };

    metricsListenAddr = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:9090";
      description = "Address:port for Prometheus metrics.";
    };

    # Database - using sqlite for simplicity, can upgrade to postgres later
    database = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        type = "sqlite3";
        # Stored on persistent ZFS dataset
        url = "file:/var/lib/headscale/db.sqlite?mode=rwc&_fk=1";
      };
      description = "Database configuration (sqlite3 or postgres).";
    };

    # DERP/STUN for NAT traversal
    derp = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
      default = {
        server = {
          enabled = "true";  # Local DERP enabled - UDP 3478 port-forwarded via IPv6
          regionId = "999";
          regionCode = "jupiter";
          regionName = "Jupiter DERP";
          stunPort = "3478";
        };
        urls = [];
        paths = [];
        # Prefer local DERP now that port 3478 is open
        preferDerp = "true";
      };
      description = "DERP server configuration. Local DERP enabled (UDP 3478 port-forwarded via IPv6).";
    };

    # Policy/ACLs
    policy = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        mode = "file";
        path = "/etc/headscale/policy.hujson";
      };
      description = "ACL policy configuration.";
    };

    # Ephemeral node settings (for CI runners)
    ephemeralNode = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        enabled = "true";
        # Reusable pre-auth keys for CI
        reusable = "true";
      };
      description = "Ephemeral node settings for CI runners.";
    };

    # DNS
    dns = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        # Use MagicDNS
        enabled = "true";
        # Upstream DNS for tailnet
        upstream = "10.1.1.1,1.1.1.1";
      };
      description = "DNS/MagicDNS configuration.";
    };

    # Log level
    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "info";
      description = "Log level (debug, info, warn, error).";
    };

    # TLS - using Cloudflare Tunnel for HTTPS, so HTTP internally
    tls = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        certPath = "";
        keyPath = "";
        letsencrypt = "false";
        letsencryptListen = ":443";
      };
      description = "TLS configuration (empty = HTTP only, use Cloudflare Tunnel).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Create headscale user and data directory
    users.users.headscale = {
      isSystemUser = true;
      home = "/var/lib/headscale";
      description = "Headscale control plane server";
      group = "headscale";
    };
    users.groups.headscale = { };

    # Data directory on persistent storage
    systemd.tmpfiles.rules = [
      "d /var/lib/headscale 0750 headscale headscale - -"
      "d /etc/headscale 0750 headscale headscale - -"
    ];

    # ACL policy file
    environment.etc."headscale/policy.hujson".text = builtins.toJSON {
      groups = {
        admin = [ "admin@jupiter" ];
        fleet = [ "europa" "callisto" "amalthea" "metis" "adrastea" "thebe" ];
        ci = [ "tag:ci" ];
      };
      hosts = {
        # Fleet hosts can talk to each other
        "fleet" = [ "fleet" ];
        # CI can talk to fleet (to push to europa's Harmonia)
        "tag:ci" = [ "fleet" ];
        # Admin can do everything
        "admin" = [ "*" ];
      };
      # Tag owners for ephemeral nodes
      tagOwners = {
        "tag:ci" = [ "admin@jupiter" ];
      };
      # ACLs
      acls = [
        # Fleet hosts can talk to each other on any port
        { action = "accept"; src = [ "fleet" ]; dst = [ "fleet:*" ]; }
        # CI can push to europa's Harmonia (port 5000) and SSH to fleet (port 22)
        { action = "accept"; src = [ "tag:ci" ]; dst = [ "fleet:5000" "fleet:22" ]; }
        # Admin full access
        { action = "accept"; src = [ "admin" ]; dst = [ "*:*" ]; }
      ];
    };

    # Headscale service
    systemd.services.headscale = {
      description = "Headscale control plane server";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        User = "headscale";
        Group = "headscale";
        WorkingDirectory = "/var/lib/headscale";
        Environment = [
          "HEADSCALE_SERVER_URL=${cfg.serverUrl}"
          "HEADSCALE_LISTEN_ADDR=${cfg.listenAddr}"
          "HEADSCALE_METRICS_LISTEN_ADDR=${cfg.metricsListenAddr}"
          "HEADSCALE_DATABASE_TYPE=${cfg.database.type}"
          "HEADSCALE_DATABASE_URL=${cfg.database.url}"
          "HEADSCALE_DERP_SERVER_ENABLED=${cfg.derp.server.enabled}"
          "HEADSCALE_DERP_SERVER_REGION_ID=${cfg.derp.server.regionId}"
          "HEADSCALE_DERP_SERVER_REGION_CODE=${cfg.derp.server.regionCode}"
          "HEADSCALE_DERP_SERVER_REGION_NAME=${cfg.derp.server.regionName}"
          "HEADSCALE_DERP_SERVER_STUN_PORT=${cfg.derp.server.stunPort}"
          "HEADSCALE_DERP_URLS=${lib.concatStringsSep " " (cfg.derp.urls or [ ])}"
          "HEADSCALE_DERP_PATHS=${lib.concatStringsSep " " (cfg.derp.paths or [ ])}"
          "HEADSCALE_DERP_PREFER_DERP=${cfg.derp.preferDerp or "true"}"
          "HEADSCALE_POLICY_MODE=${cfg.policy.mode}"
          "HEADSCALE_POLICY_PATH=${cfg.policy.path}"
          "HEADSCALE_EPHEMERAL_ENABLED=${cfg.ephemeralNode.enabled}"
          "HEADSCALE_EPHEMERAL_REUSABLE=${cfg.ephemeralNode.reusable}"
          "HEADSCALE_DNS_ENABLED=${cfg.dns.enabled}"
          "HEADSCALE_DNS_UPSTREAM=${cfg.dns.upstream}"
          "HEADSCALE_LOG_LEVEL=${cfg.logLevel}"
          "HEADSCALE_TLS_CERT_PATH=${cfg.tls.certPath}"
          "HEADSCALE_TLS_KEY_PATH=${cfg.tls.keyPath}"
          "HEADSCALE_TLS_LETSENCRYPT=${cfg.tls.letsencrypt or "false"}"
          "HEADSCALE_TLS_LETSENCRYPT_LISTEN=${cfg.tls.letsencryptListen or ":443"}"
        ];
        ExecStart = "${pkgs.headscale}/bin/headscale serve";
        Restart = "on-failure";
        RestartSec = 5;
        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/headscale" "/etc/headscale" ];
      };
    };

    # Firewall - allow Headscale HTTP + DERP STUN
    networking.firewall.allowedTCPPorts = lib.mkAfter [ 8080 ];
    networking.firewall.allowedUDPPorts = lib.mkAfter [ 3478 ];

    # Enable service
    systemd.services.headscale.enable = true;
  };
}