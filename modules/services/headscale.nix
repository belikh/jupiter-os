{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.jupiter.services.headscale;

  # Generate headscale config.yaml
  configYaml = ''
    server_url: ${cfg.serverUrl}
    listen_addr: ${cfg.listenAddr}
    metrics_listen_addr: ${cfg.metricsListenAddr}
    database:
      type: ${cfg.database.type}
      sqlite:
        path: ${cfg.database.path}
    noise:
      private_key_path: /var/lib/headscale/noise_private.key
    prefixes:
      v4: ${cfg.prefixes.v4}
      v6: ${cfg.prefixes.v6}
      allocation: sequential
    derp:
      server:
        enabled: ${cfg.derp.server.enabled}
        region_id: ${cfg.derp.server.regionId}
        region_code: ${cfg.derp.server.regionCode}
        region_name: ${cfg.derp.server.regionName}
        stun_listen_addr: "0.0.0.0:${cfg.derp.server.stunPort}"
        private_key_path: /var/lib/headscale/derp_server_private.key
      urls: ${lib.concatStringsSep "\n  " (lib.map (u: "- ${u}") (cfg.derp.urls or [ ]))}
      paths: ${lib.concatStringsSep "\n  " (lib.map (p: "- ${p}") (cfg.derp.paths or [ ]))}
      prefer_derp: ${cfg.derp.preferDerp or "true"}
    policy:
      mode: ${cfg.policy.mode}
      path: ${cfg.policy.path}
    dns:
      magic_dns: ${cfg.dns.enabled}
      base_domain: ${cfg.dns.baseDomain}
      override_local_dns: true
      nameservers:
        global: ${lib.concatStringsSep "\n        - " (lib.splitString "," cfg.dns.upstream)}
      search_domains: []
    log:
      level: ${cfg.logLevel}
      format: text
    # Top-level flat keys, NOT nested under a "tls:" object — confirmed
    # against config-example.yaml. A nested "tls:" block (the previous
    # shape here) is an unknown key headscale silently ignores, which
    # silently no-ops cfg.tls entirely rather than erroring.
    tls_cert_path: ${cfg.tls.certPath}
    tls_key_path: ${cfg.tls.keyPath}
    # unix_socket's real default (/var/run/headscale/headscale.sock) sits
    # outside this unit's ReadWritePaths — ProtectSystem=strict makes /run
    # read-only unless explicitly listed, so the CLI-control socket would
    # fail to bind. Point it at the already-writable state dir instead.
    unix_socket: /var/lib/headscale/headscale.sock
  '';
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

    # Database - using sqlite for simplicity, can upgrade to postgres later.
    # 0.29.3 schema: database.type is "sqlite" (not "sqlite3") and the file
    # path lives under database.sqlite.path (not a flat url:) — confirmed
    # against the real config-example.yaml after "path cannot be empty".
    database = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        type = "sqlite";
        # Stored on persistent ZFS dataset
        path = "/var/lib/headscale/db.sqlite";
      };
      description = "Database configuration (sqlite or postgres).";
    };

    # DERP/STUN for NAT traversal
    derp = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
      default = {
        server = {
          enabled = "true"; # Local DERP enabled - UDP 3478 port-forwarded via IPv6
          regionId = "999";
          regionCode = "jupiter";
          regionName = "Jupiter DERP";
          stunPort = "3478";
        };
        urls = [ ];
        paths = [ ];
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

    # Tailnet IP allocation ranges. Required by headscale 0.29.3 (config
    # init fails with "no IPv4 or IPv6 prefix configured" if absent) —
    # standard Tailscale-compatible CGNAT/ULA ranges.
    prefixes = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        v4 = "100.64.0.0/10";
        v6 = "fd7a:115c:a1e0::/48";
      };
      description = "Tailnet IPv4/IPv6 address allocation ranges.";
    };

    # DNS
    dns = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        # Use MagicDNS
        enabled = "true";
        # Upstream DNS for tailnet
        upstream = "10.1.1.1,1.1.1.1";
        # Base domain MagicDNS serves node names under (<node>.<baseDomain>).
        # Deliberately distinct from serverUrl's headscale.jupiter.au to avoid
        # the control-plane hostname colliding with the tailnet DNS zone.
        baseDomain = "ts.jupiter.au";
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
        fleet = [
          "europa"
          "callisto"
          "amalthea"
          "metis"
          "adrastea"
          "thebe"
        ];
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
        "tag:fleet" = [ "admin@jupiter" ];
      };
      # ACLs
      acls = [
        # Fleet hosts can talk to each other on any port
        {
          action = "accept";
          src = [ "fleet" ];
          dst = [ "fleet:*" ];
        }
        # CI can push to europa's Harmonia (port 5000) and SSH to fleet (port 22)
        {
          action = "accept";
          src = [ "tag:ci" ];
          dst = [
            "fleet:5000"
            "fleet:22"
          ];
        }
        # Admin full access
        {
          action = "accept";
          src = [ "admin" ];
          dst = [ "*:*" ];
        }
      ];
    };

    # Headscale config file
    environment.etc."headscale/config.yaml".text = configYaml;

    # Generate noise private key if not exists
    systemd.services.headscale = {
      description = "Headscale control plane server";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        User = "headscale";
        Group = "headscale";
        WorkingDirectory = "/var/lib/headscale";
        ExecStartPre = [
          # Generate noise private key if not exists. Bare command names
          # aren't resolved via PATH for Exec*= under this hardened unit, and
          # a compound `if` line isn't a single executable+args, so each step
          # needs an absolute path / an explicit shell wrapper.
          "${pkgs.coreutils}/bin/mkdir -p /var/lib/headscale"
          "${pkgs.coreutils}/bin/chown headscale:headscale /var/lib/headscale"
          # `headscale noise genkey` isn't a real subcommand (silently
          # failed, leaving an empty key file that then failed to parse:
          # "key hex string doesn't have expected type prefix privkey:") —
          # the actual command is `generate private-key`, which prints the
          # already-prefixed key ("privkey:<hex>") to stdout.
          "${pkgs.bash}/bin/sh -c 'if [ ! -s /var/lib/headscale/noise_private.key ]; then ${pkgs.headscale}/bin/headscale generate private-key > /var/lib/headscale/noise_private.key; ${pkgs.coreutils}/bin/chown headscale:headscale /var/lib/headscale/noise_private.key; fi'"
        ];
        ExecStart = "${pkgs.headscale}/bin/headscale -c /etc/headscale/config.yaml serve";
        Restart = "on-failure";
        RestartSec = 5;
        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [
          "/var/lib/headscale"
          "/etc/headscale"
        ];
      };
    };

    # Firewall - allow Headscale HTTP + DERP STUN
    networking.firewall.allowedTCPPorts = lib.mkAfter [ 8080 ];
    networking.firewall.allowedUDPPorts = lib.mkAfter [ 3478 ];

    # Enable service
    systemd.services.headscale.enable = true;
  };
}
