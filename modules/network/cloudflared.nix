{ config, ... }:

let
  # Tunnel id + ingress map shared with terraform/cloudflare (the public DNS
  # records), so the routed hostnames are stated once. See lib/site.nix.
  site = import ../../lib/site.nix;
in
{
  # sopsFile defaults to sops.defaultSopsFile (set in modules/common.nix).
  sops.secrets.cloudflare_cert = { };

  services.cloudflared = {
    enable = true;
    tunnels.${site.tunnel.id} = {
      credentialsFile = config.sops.secrets.cloudflare_cert.path;
      default = "http_status:404";
      ingress = site.tunnel.ingress;
    };
  };
}
