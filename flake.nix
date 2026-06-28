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
      # completely avoiding the "specialArgs" anti-pattern. `extraModules` lets a
      # host pull in flake-level wiring (e.g. cross-host build products).
      mkHost =
        hostPath: extraModules:
        nixpkgs.lib.nixosSystem {
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
          ]
          ++ extraModules;
        };

      # Wire the PXE server (on lenovo) directly to the elitedesk's netboot build
      # products, so the image Pixiecore serves always matches the flake. The
      # cmdLine must point the booting kernel at its closure's init.
      elitedeskConfig = self.nixosConfigurations.elitedesk.config;
      elitedeskBuild = elitedeskConfig.system.build;
      pxeModule = { ... }: {
        jupiter.pxe = {
          enable = true;
          kernel = "${elitedeskBuild.kernel}/bzImage";
          initrd = "${elitedeskBuild.netbootRamdisk}/initrd";
          # Pull kernelParams from elitedesk itself so the served cmdLine can't
          # drift from the host's config (it already sets copytoram).
          cmdLine = "init=${elitedeskBuild.toplevel}/init loglevel=4 ${toString elitedeskConfig.boot.kernelParams}";
        };
      };
    in
    {
      nixosConfigurations = {
        elitedesk = mkHost ./hosts/elitedesk/configuration.nix [ ];
        lenovo = mkHost ./hosts/lenovo/configuration.nix [ pxeModule ];
        t460s = mkHost ./hosts/t460s/configuration.nix [ ];
        nas = mkHost ./hosts/nas/configuration.nix [ ];
        dashboards = mkHost ./hosts/dashboards/configuration.nix [ ];
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
        t460s = {
          hostname = "t460s";
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.t460s;
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

      # Repo formatter (`nix fmt` / `make fmt`)
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-rfc-style;

      # Extract devShell to a traditional shell.nix using callPackage
      devShells.x86_64-linux.default = nixpkgs.legacyPackages.x86_64-linux.callPackage ./shell.nix {
        deploy-rs = deploy-rs;
      };
    };
}
