{ lib, ... }:

let
  # Public zone + tunnel facts shared with the cloudflared config — see
  # lib/site.nix. Each routed hostname gets a proxied CNAME to the tunnel.
  site = import ../../lib/site.nix;
  tunnelTarget = "${site.tunnel.id}.cfargotunnel.com";

  mkRecord = host: _backend: {
    zone_id = "\${data.cloudflare_zone.jupiter_au.id}";
    name = host;
    type = "CNAME";
    value = tunnelTarget;
    proxied = true; # orange-cloud: traffic enters via Cloudflare → the tunnel
  };
in
{
  terraform = {
    required_providers = {
      cloudflare = {
        source = "cloudflare/cloudflare";
        version = "~> 4.0";
      };
    };
  };

  variable = {
    cloudflare_api_token = {
      type = "string";
      sensitive = true;
    };
  };

  provider.cloudflare = {
    api_token = "\${var.cloudflare_api_token}";
  };

  data.cloudflare_zone.jupiter_au = {
    name = site.publicZone;
  };

  # Public DNS for the tunnel hostnames (headscale/n8n/ha) — generated from the
  # same ingress map cloudflared uses, so DNS and tunnel routing can't drift.
  resource.cloudflare_record = lib.mapAttrs' (
    host: backend: lib.nameValuePair (lib.replaceStrings [ "." ] [ "_" ] host) (mkRecord host backend)
  ) site.tunnel.ingress;
}
