{
  description = "Jupiter OS - NixOS Monorepo";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Secrets management
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Remote deployment tool
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # OpenWrt Image Builder for the Linksys MX4300 APs
    nix-openwrt-imagebuilder.url = "github:astro/nix-openwrt-imagebuilder";

    # Declarative partitioning
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Impermanence (Erase your darlings)
    impermanence = {
      url = "github:nix-community/impermanence";
    };

    # Terranix
    terranix = {
      url = "github:terranix/terranix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      sops-nix,
      deploy-rs,
      nix-openwrt-imagebuilder,
      disko,
      impermanence,
      terranix,
      ...
    }:
    let
      # A helper function that injects third-party modules cleanly via a lexical closure,
      # completely avoiding the "specialArgs" anti-pattern.
      mkHost = hostPath: nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          # 1. Inject flake-provided modules natively
          ({ ... }: {
            imports = [
              sops-nix.nixosModules.sops
              impermanence.nixosModules.impermanence
              disko.nixosModules.disko
            ];
          })
          # 2. Import the actual host configuration
          hostPath
        ];
      };
    in
    {
      nixosConfigurations = {
        elitedesk = mkHost ./hosts/elitedesk/configuration.nix;
        lenovo = mkHost ./hosts/lenovo/configuration.nix;
        t460s = mkHost ./hosts/t460s/configuration.nix;
        nas = mkHost ./hosts/nas/configuration.nix;
        dashboards = mkHost ./hosts/dashboards/configuration.nix;
      };

      packages.x86_64-linux =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
        in
        {
          # Call the extracted builder function, allowing infinite custom variants
          mx4300-firmware = pkgs.callPackage ./packages/openwrt-builder/default.nix {
            nix-openwrt-imagebuilder = nix-openwrt-imagebuilder;
            profile = "linksys_mx4300";
            extraPackages = [
              "wpad-mesh-openssl"
              "batctl-default"
              "kmod-batman-adv"
              "kmod-8021q"
              "sqm-scripts"
            ];
          };

          terranix-cloudflare = terranix.lib.terranixConfiguration {
            system = "x86_64-linux";
            modules = [ ./terraform/cloudflare/default.nix ];
          };

          terranix-unifi = terranix.lib.terranixConfiguration {
            system = "x86_64-linux";
            modules = [ ./terraform/unifi/default.nix ];
          };
        };

      # Deployment configuration for deploy-rs
      deploy.nodes = {
        lenovo = {
          hostname = "lenovo";
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.lenovo;
          };
        };
        nas = {
          hostname = "nas";
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.nas;
          };
        };
        elitedesk = {
          hostname = "elitedesk";
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.elitedesk;
          };
        };
        dashboards = {
          hostname = "dashboards";
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.dashboards;
          };
        };
      };

      # Add deploy-rs checks
      checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;

      # Extract devShell to a traditional shell.nix using callPackage
      devShells.x86_64-linux.default = nixpkgs.legacyPackages.x86_64-linux.callPackage ./shell.nix {
        deploy-rs = deploy-rs;
      };
    };
}
