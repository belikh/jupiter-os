{
  config,
  lib,
  ...
}:

# Cloudflare Tunnel (cloudflared) — exposes LAN-bound services to the public
# internet without opening router ports. On this branch europa runs it itself
# (the master branch ran it on ganymede, which isn't registered here yet); the
# deferred-followup is to move it back to ganymede once that host exists.
#
# The primary use case today: europa's Harmonia cache (services.harmonia on :5000)
# is reached at cache.jupiter.au so the fleet and roaming hosts can pull from it.
# The tunnel credentials live in the cloudflare_cert sops secret (already in
# secrets/secrets.yaml).

let
  cfg = config.jupiter.services.cloudflareTunnel;
in
{
  options.jupiter.services.cloudflareTunnel = {
    enable = lib.mkEnableOption "the Cloudflare Tunnel (cloudflared)";

    tunnelId = lib.mkOption {
      type = lib.types.str;
      example = "a1b2c3d4-...";
      description = ''
        The Cloudflare tunnel UUID. The matching credentials JSON must be in
        the cloudflare_cert sops secret, and the hostname routes must be
        configured on the Cloudflare dashboard side (the tunnel's ingress).
        Confirm at first run.
      '';
    };

    harmoniaHostname = lib.mkOption {
      type = lib.types.str;
      default = "cache.jupiter.au";
      description = "Public hostname routing to europa's Harmonia cache (localhost:5000).";
    };

    harmoniaPort = lib.mkOption {
      type = lib.types.port;
      default = 5000;
      description = "Port Harmonia listens on locally (the tunnel's upstream).";
    };

    extraIngress = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            hostname = lib.mkOption {
              type = lib.types.str;
              description = "Public hostname for this ingress rule";
            };
            host = lib.mkOption {
              type = lib.types.str;
              default = "localhost";
              description = ''
                Upstream host to proxy to. cloudflared runs on this host
                (europa) but can proxy to anywhere reachable from it — set
                this to a LAN IP to expose a service running on a different
                host (e.g. callisto) without running a second tunnel.
              '';
            };
            port = lib.mkOption {
              type = lib.types.port;
              description = "Upstream port";
            };
          };
        }
      );
      default = [ ];
      description = "Additional ingress rules for the tunnel: hostname → host:port";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.cloudflare_cert = { };

    services.cloudflared = {
      enable = true;
      tunnels.${cfg.tunnelId} = {
        credentialsFile = config.sops.secrets.cloudflare_cert.path;
        # Route the Harmonia cache hostname to local Harmonia; everything else 404.
        # Add more ingress rules here as services come back up.
        ingress = {
          ${cfg.harmoniaHostname} = "http://localhost:${toString cfg.harmoniaPort}";
        }
        // builtins.listToAttrs (
          map (rule: {
            name = rule.hostname;
            value = "http://${rule.host}:${toString rule.port}";
          }) cfg.extraIngress
        );
        originRequest.noTLSVerify = true;
        default = "http_status:404";
      };
    };
  };
}
