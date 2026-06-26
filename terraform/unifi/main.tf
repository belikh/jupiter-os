terraform {
  required_providers {
    unifi = {
      source  = "paultyng/unifi"
      version = "~> 0.41.0"
    }
  }
}

provider "unifi" {
  # These will be populated from your age/sops secrets when you run terraform
  username = "admin"
  password = "password"
  api_url  = "https://10.1.1.1" # UDM Pro IP
  allow_insecure = true
}

# Example declarative configuration for your Wi-Fi
# resource "unifi_wlan" "jupiter_wifi" {
#   name       = "JupiterMesh"
#   passphrase = "super_secret_password"
#   security   = "wpapsk"
#   network_id = "default"
# }
