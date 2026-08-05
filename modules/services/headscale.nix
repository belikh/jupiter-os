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
        ${lib.optionalString (cfg.derp.server.ipv4 or "" != "") "ipv4: ${cfg.derp.server.ipv4}"}
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

    # Real headscale user identity (created via `headscale users create`),
    # granted admin ACL access and tag:ci/tag:fleet ownership. Was
    # previously the placeholder "admin@jupiter", which isn't a real
    # headscale user — tag:fleet registration failed with "requested tags
    # [tag:fleet] are invalid or not permitted" until fixed. Must be
    # email-shaped: groups{} members fail policy parsing otherwise
    # ("username must contain @") even though tagOwners accepts a bare
    # name — confirmed live, a bare "io" parsed fine for tagOwners but
    # broke groups.
    adminUser = lib.mkOption {
      type = lib.types.str;
      default = "io@jupiter.au";
      description = "headscale user identity for ACL group:admin and tag ownership.";
    };

    # Server configuration. NOTE: headscale derives the DERP relay's
    # advertised port DIRECTLY from this URL's scheme+port (confirmed in
    # hscontrol/derp/server/derp_server.go's GenerateRegion — no separate
    # DERP-port option exists). https://headscale.jupiter.au implies
    # DERPPort 443, which only the (Cloudflare-Tunnel-fronted, TLS-broken
    # for this purpose) public hostname serves — unreachable for IPv4-only
    # clients like GitHub-hosted CI runners. europa overrides this to the
    # plain-HTTP direct port-forward instead (see hosts/europa).
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
          # Public IPv4 to advertise for the DERP relay, so clients connect
          # directly by IP instead of resolving HostName (which is
          # server_url's host — see serverUrl's doc comment on why that
          # matters for CI reachability). Empty = omitted from config.yaml.
          ipv4 = "";
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

    # ACL policy file. headscale's v2 policy schema (confirmed against
    # hscontrol/policy/v2/testdata/acl_results/*.hujson in the real repo,
    # after "group must start with 'group:', got: \"admin\""):
    #   - groups{} keys must be prefixed "group:", and members must be user
    #     identities (emails) — NOT device hostnames or tags.
    #   - hosts{} maps a name to a SINGLE CIDR/IP string (e.g.
    #     "internal": "10.0.0.0/8"), not a list — it's for literal
    #     IP/subnet aliases, not a way to group devices.
    # The previous shape put device hostnames in groups.fleet and abused
    # hosts{} (as list-valued) to alias "fleet"/"tag:ci" to a device list —
    # invalid on every count. Since every fleet host already advertises
    # tag:fleet (tagOwners below), ACLs reference tag:fleet/tag:ci directly
    # instead — no groups{}/hosts{} indirection needed for devices at all.
    environment.etc."headscale/policy.hujson".text = builtins.toJSON {
      groups = {
        "group:admin" = [ cfg.adminUser ];
      };
      tagOwners = {
        "tag:ci" = [ cfg.adminUser ];
        "tag:fleet" = [ cfg.adminUser ];
      };
      acls = [
        # Fleet hosts can talk to each other on any port
        {
          action = "accept";
          src = [ "tag:fleet" ];
          dst = [ "tag:fleet:*" ];
        }
        # CI can push to europa's Harmonia (port 5000) and SSH to fleet (port 22)
        {
          action = "accept";
          src = [ "tag:ci" ];
          dst = [
            "tag:fleet:5000"
            "tag:fleet:22"
          ];
        }
        # Admin full access
        {
          action = "accept";
          src = [ "group:admin" ];
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
      # switch-to-configuration only auto-restarts a service when the UNIT
      # itself changes — plain environment.etc content changes (this
      # config.yaml) are invisible to it otherwise, so every config fix
      # this file has had needed a manual `systemctl restart headscale` to
      # actually take effect after a switch (confirmed live, repeatedly).
      restartTriggers = [ config.environment.etc."headscale/config.yaml".source ];
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
