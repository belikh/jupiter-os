{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.jupiter.services.tailscale;

  # TODO(upstream-port decision): nixpkgs' services.tailscale exists at this
  # pin and covers most of this module (package, daemon, up-flags via
  # services.tailscale.extraUpFlags... plus openFirewall/authKey handling).
  # This hand-rolled module predates verifying that, and carries fleet-specific
  # deviations (custom stateDir + socket path, loginServer pointing at
  # europa's headscale, authKeyFile via sops, the reset semantics documented
  # below). Migrating is a behavior change on 6 live hosts and must be done as
  # an eval-diff + on-host verification pass (`nix eval` both trees' units,
  # then one host at a time) — not silently in a refactor commit. Same applies
  # to modules/services/headscale.nix vs nixpkgs' services.headscale.

  # Build the tailscale up command as a list of arguments. --socket must
  # match tailscaled's own --socket below (custom stateDir path, not the
  # tailscale CLI's default /var/run/tailscale/tailscaled.sock) — it's a
  # global flag so it goes before the "up" subcommand, or the CLI fails
  # with "failed to connect to local tailscaled; it doesn't appear to be
  # running" even though the daemon is up.
  upArgs = lib.concatLists [
    [
      "${pkgs.tailscale}/bin/tailscale"
      "--socket=${cfg.stateDir}/tailscaled.sock"
      "up"
      # This unit re-runs `tailscale up` with our declared flags on every
      # activation/restart. Without --reset, tailscale refuses to apply a
      # flag set that differs from whatever was persisted by a PREVIOUS
      # `up` invocation (e.g. an earlier manual registration that included
      # --advertise-tags, now correctly dropped below): "changing settings
      # via 'tailscale up' requires mentioning all non-default flags."
      # --reset makes each run fully declarative instead of an incremental
      # diff against prior state — confirmed live on europa. --reset alone
      # isn't enough when login-server itself changes though ("can't
      # change --login-server without --force-reauth", also confirmed
      # live) — re-registering against a different control server is
      # treated as a bigger change than --reset covers.
      "--reset"
      "--force-reauth"
    ]
    [ "--login-server=${cfg.serverUrl}" ]
    (lib.optional (cfg.authKeyFile != null) [ "--authkey=file:${cfg.authKeyFile}" ])
    (lib.optional (cfg.hostname != "") [ "--hostname=${cfg.hostname}" ])
    # headscale 0.29.3 HARD-REJECTS registration if --advertise-tags is
    # combined with a PreAuthKey that already carries tags (this is how
    # every host here registers now) — confirmed in hscontrol/state/state.go:
    # "Reject advertise-tags for PreAuthKey registrations early... PreAuthKey
    # nodes get their tags from the key itself, not from client requests."
    # Not a harmless redundant flag; a hard registration failure
    # ("requested tags [...] are invalid or not permitted"). Only emit
    # --advertise-tags for the authKeyFile-less (interactive/manual
    # registration) case.
    (lib.optionals (cfg.authKeyFile == null) (
      lib.concatMap (tag: [ "--advertise-tags=${tag}" ]) cfg.tags
    ))
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
      after = [
        "network-online.target"
        "tailscaled.service"
      ];
      wants = [
        "network-online.target"
        "tailscaled.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # A list here would be interpreted as multiple ExecStart= directives
        # (systemd's syntax for a command sequence), not one command with
        # multiple args — collapse to a single quoted command line.
        ExecStart = lib.escapeShellArgs upArgs;
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
