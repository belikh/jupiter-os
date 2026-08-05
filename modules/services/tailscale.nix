{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.jupiter.services.tailscale;

  # Build the tailscale up command as a list of arguments
  upArgs = lib.concatLists [
    [ "${pkgs.tailscale}/bin/tailscale" "up" ]
    [ "--login-server=${cfg.serverUrl}" ]
    (lib.optional (cfg.authKeyFile != null) [ "--authkey=file:${cfg.authKeyFile}" ])
    (lib.optional cfg.ephemeral [ "--ephemeral" ])
    (lib.optional (cfg.hostname != "") [ "--hostname=${cfg.hostname}" ])
    (lib.concatMap (tag: [ "--advertise-tags=${tag}" ]) cfg.tags)
    (lib.optional cfg.acceptRoutes [ "--accept-routes" ])
    (lib.concatMap (route: [ "--advertise-routes=${route}" ]) cfg.advertiseRoutes)
  ];
in
{
  options.jupiter.services.tailscale = {
    enable = lib.mkEnableOption "Tailscale client (connects to Jupiter Headscale)";

    # Headscale server URL
    serverUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://headscale.jupiter.au";
      description = "Headscale control plane URL.";
    };

    # Auth key (from sops) - one-time or reusable
    authKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to Tailscale auth key file (sops secret). Optional - can use headscale pre-auth keys instead.";
    };

    # Ephemeral node (for CI runners)
    ephemeral = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Register as ephemeral node (auto-cleanup on disconnect).";
    };

    # Hostname override (defaults to networking.hostName)
    hostname = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Override hostname for Tailscale registration.";
    };

    # Tags (for ACL policy matching)
    tags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Tags to apply (e.g., ['tag:ci']).";
    };

    # Accept routes from other nodes
    acceptRoutes = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Accept advertised routes from other tailnet nodes.";
    };

    # Advertise routes (for subnet routers)
    advertiseRoutes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Routes to advertise (e.g., ['10.1.1.0/24']).";
    };

    # State directory
    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/tailscale";
      description = "Tailscale state directory.";
    };

    # Log level
    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "info";
      description = "Log level (debug, info, warn, error).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Main tailscaled daemon service
    systemd.services.tailscaled = {
      description = "Tailscale daemon (Jupiter tailnet)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.tailscale}/bin/tailscaled --state=${cfg.stateDir}/tailscaled.state --socket=${cfg.stateDir}/tailscaled.sock --port=41641";
        Restart = "on-failure";
        RestartSec = 5;
        # Tailscale needs NET_ADMIN
        CapabilityBoundingSet = "CAP_NET_ADMIN CAP_NET_RAW CAP_DAC_OVERRIDE";
        AmbientCapabilities = "CAP_NET_ADMIN CAP_NET_RAW CAP_DAC_OVERRIDE";
      };
    };

    # Tailscale up service (runs after tailscaled is ready)
    systemd.services.tailscale-up = {
      description = "Tailscale registration (Jupiter tailnet)";
      after = [ "network-online.target" "tailscaled.service" ];
      wants = [ "network-online.target" "tailscaled.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = upArgs;
      };
    };

    # Ensure state directory exists
    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 root root - -"
    ];

    # Enable services
    systemd.services.tailscaled.enable = true;
    systemd.services.tailscale-up.enable = true;

    # Firewall - allow Tailscale traffic
    networking.firewall.allowedTCPPorts = lib.mkAfter [ 41641 ];
    networking.firewall.allowedUDPPorts = lib.mkAfter [ 41641 ];
  };
}