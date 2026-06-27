terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

data "cloudflare_zone" "jupiter_au" {
  name = "jupiter.au"
}

# Add any required public records here.
# E.g.
# resource "cloudflare_record" "www" {
#   zone_id = data.cloudflare_zone.jupiter_au.id
#   name    = "www"
#   value   = "1.2.3.4"
#   type    = "A"
#   proxied = true
# }

# AussieBB delegated IPv6 reverse DNS zones placeholder
# You will need to define the reverse zone provided by AussieBB.
# e.g., 
# resource "cloudflare_zone" "reverse_ipv6" {
#   account_id = "<your-account-id>"
#   zone       = "0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa"
# }
