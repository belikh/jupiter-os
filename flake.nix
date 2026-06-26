{
  description = "Jupiter OS - NixOS Monorepo";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    
    # Secrets management
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Home Manager
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # OpenWrt Image Builder for the Linksys MX4300 APs
    nix-openwrt-imagebuilder.url = "github:astro/nix-openwrt-imagebuilder";
  };

  outputs = { self, nixpkgs, sops-nix, home-manager, nix-openwrt-imagebuilder, ... }@inputs: {
    nixosConfigurations = {
      # Current Proxmox host -> Bare-metal NixOS
      lenovo = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/lenovo/configuration.nix
          sops-nix.nixosModules.sops
        ];
      };

      # Current laptop
      t460s = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/t460s/configuration.nix
          sops-nix.nixosModules.sops
        ];
      };

      # Future NAS
      nas = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/nas/configuration.nix
          sops-nix.nixosModules.sops
        ];
      };

      # Base Kiosk Dashboard Profile
      dashboards = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/dashboards/configuration.nix
          sops-nix.nixosModules.sops
        ];
      };
    };

    # OpenWrt Firmware builds for the 4x Linksys HomeWRK MX4300
    packages.x86_64-linux = let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in {
      mx4300-firmware = nix-openwrt-imagebuilder.lib.build {
        inherit pkgs;
        target = "ipq807x/generic";
        profile = "linksys_mx4300"; # Exact profile name for 24.10+
        packages = [ 
          "wpad-mesh-openssl" 
          "batctl-default" 
          "kmod-batman-adv" 
          "sqm-scripts" 
          "nano"
        ];
        # Any static configuration files to inject into the firmware (e.g., uci-defaults)
        files = ./hosts/access-points/mx4300-files;
      };
    };
  };
}
