{ config, lib, pkgs, ... }:

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
    name = "jupiter.au";
  };
}
