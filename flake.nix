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

    # Declarative user environment (dotfiles, per-user packages, niri config),
    # shared across the personal machines so a login looks the same everywhere.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Terranix
    terranix = {
      url = "github:terranix/terranix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # SteamOS "gaming mode" gamescope session, Steam Deck quirks, Decky Loader.
    jovian = {
      url = "github:Jovian-Experiments/Jovian-NixOS";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # CachyOS kernel, mesa-git, sched-ext (scx), gamescope_git. Deliberately
    # NOT following nixpkgs so its substituter (cache.chaotic.cx) stays useful.
    chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";
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
      home-manager,
      terranix,
      jovian,
      chaotic,
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
                # Bazzite-on-Nix building blocks. Inert unless a host opts into
                # jupiter.gaming.bazzite, but injected everywhere so any machine
                # can attach the gaming profile (see modules/gaming/bazzite.nix).
                jovian.nixosModules.default
                chaotic.nixosModules.default
                # Declarative per-user environment. Inert unless a host sets
                # jupiter.home.enable (see modules/home).
                home-manager.nixosModules.home-manager
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

      # The NAS auto-derives its syncoid replication sources from every OTHER
      # host's jupiter.backup declaration — so adding a host that holds state
      # wires up central backup with no edit here. Same cross-host-via-closure
      # pattern as pxeModule above. (Reading other hosts' config is acyclic: they
      # never read the NAS's config.)
      site = import ./lib/site.nix;
      backupHubModule =
        { lib, ... }:
        let
          otherHosts = lib.filterAttrs (name: _: name != site.backupHub.host) self.nixosConfigurations;
          replicating = lib.filterAttrs (_: node: node.config.jupiter.backup.enable) otherHosts;
          sourcesFor =
            name: node:
            lib.listToAttrs (
              map (
                ds:
                let
                  leaf = lib.last (lib.splitString "/" ds);
                in
                lib.nameValuePair "${name}-${leaf}" {
                  remote = "root@${name}.${site.domain}";
                  sourceDataset = ds;
                  # Flat target name (no intermediate dataset to pre-create).
                  targetDataset = "tank/backups/${name}-${leaf}";
                }
              ) node.config.jupiter.backup.datasets
            );
        in
        {
          jupiter.replication.sources = lib.mkMerge (lib.mapAttrsToList sourcesFor replicating);
        };
    in
    {
      nixosConfigurations = {
        elitedesk = mkHost ./hosts/elitedesk/configuration.nix [ ];
        lenovo = mkHost ./hosts/lenovo/configuration.nix [ pxeModule ];
        t460s = mkHost ./hosts/t460s/configuration.nix [ ];
        nas = mkHost ./hosts/nas/configuration.nix [ backupHubModule ];
        dashboards = mkHost ./hosts/dashboards/configuration.nix [ ];

        # Future personal workstations (roaming desktop — same niri + synced
        # $HOME as the laptop). Scaffolded in hosts/ but not registered until the
        # hardware exists, because their REPLACE-ME disks would (intentionally)
        # fail the jupiter.storage assertion at build time. To bring one online:
        # fill in its disk/hostId, uncomment, and add it to the CI build matrix.
        # desktop        = mkHost ./hosts/desktop/configuration.nix [ ];
        # parents-desktop = mkHost ./hosts/parents-desktop/configuration.nix [ ];
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
