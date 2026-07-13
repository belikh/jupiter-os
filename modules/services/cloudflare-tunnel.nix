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
# The primary use case today: europa's atticd (modules/services/attic-server.nix)
# is reached at attic.jupiter.au so the remote BinaryLane build server
# (pallene) can push tuned closures and future roaming hosts can pull them.
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

    atticHostname = lib.mkOption {
      type = lib.types.str;
      default = "attic.jupiter.au";
      description = "Public hostname routing to europa's atticd (localhost:8080).";
    };

    atticPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port atticd listens on locally (the tunnel's upstream).";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.cloudflare_cert = { };

    services.cloudflared = {
      enable = true;
      tunnels.${cfg.tunnelId} = {
        credentialsFile = config.sops.secrets.cloudflare_cert.path;
        # Route the attic hostname to the local atticd; everything else 404.
        # Add more ingress rules here as services come back up.
        ingress = {
          ${cfg.atticHostname} = "http://localhost:${toString cfg.atticPort}";
        };
        originRequest.noTLSVerify = true;
        default = "http_status:404";
      };
    };
  };
}
