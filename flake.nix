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
  };

  outputs = { self, nixpkgs, sops-nix, home-manager, ... }@inputs: {
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
  };
}
