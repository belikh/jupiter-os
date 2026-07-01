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

    # CachyOS kernel, mesa-git, sched-ext (scx), gamescope_git. Deliberately
    # NOT following nixpkgs so its substituter (cache.chaotic.cx) stays useful.
    # Jovian-NixOS (SteamOS "gaming mode" gamescope session, Steam Deck quirks,
    # Decky Loader) is deliberately NOT a separate input here — chaotic-nyx
    # vendors its own Jovian copy, and Nyx's own docs require following it
    # through chaotic ("must follow jovian through chaotic to avoid hash
    # mismatches"). See `inherit (chaotic.vendored) jovian;` below.
    chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";

    # Home Assistant companion daemon for Linux hosts (sensors, notifications,
    # lock/suspend commands over MQTT discovery) — standalone project, see
    # modules/services/ha-agent.nix for the jupiter.* wiring.
    ha-linux-agent = {
      url = "github:belikh/ha-linux-agent";
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
      home-manager,
      terranix,
      chaotic,
      ha-linux-agent,
      ...
    }:
    let
      inherit (chaotic.vendored) jovian;
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
                # Home Assistant companion daemon. Inert unless a host sets
                # jupiter.services.haAgent.enable (see modules/services/ha-agent.nix).
                ha-linux-agent.nixosModules.default
              ];
            })
            # 2. Import the actual host configuration
            hostPath
          ]
          ++ extraModules;
        };

      # Wire the PXE server (on ganymede) directly to callisto's netboot build
      # products, so the image Pixiecore serves always matches the flake. The
      # cmdLine must point the booting kernel at its closure's init.
      callistoConfig = self.nixosConfigurations.callisto.config;
      callistoBuild = callistoConfig.system.build;
      pxeModule = { ... }: {
        jupiter.pxe = {
          enable = true;
          kernel = "${callistoBuild.kernel}/bzImage";
          initrd = "${callistoBuild.netbootRamdisk}/initrd";
          # Pull kernelParams from callisto itself so the served cmdLine can't
          # drift from the host's config (it already sets copytoram).
          cmdLine = "init=${callistoBuild.toplevel}/init loglevel=4 ${toString callistoConfig.boot.kernelParams}";
        };
      };

      # The NAS (europa) auto-derives its syncoid replication sources from
      # every OTHER host's jupiter.backup declaration — so adding a host that
      # holds state wires up central backup with no edit here. Same
      # cross-host-via-closure pattern as pxeModule above. (Reading other
      # hosts' config is acyclic: they never read europa's config.)
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
        callisto = mkHost ./hosts/callisto/configuration.nix [ ];
        ganymede = mkHost ./hosts/ganymede/configuration.nix [ pxeModule ];
        himalia = mkHost ./hosts/himalia/configuration.nix [ ];
        europa = mkHost ./hosts/europa/configuration.nix [ backupHubModule ];

        # TCx Wave dashboard kiosks — 4 identical units, one per room. Each is
        # its own host (own hostName/hostId/dashboard URL via
        # jupiter.dashboardKiosk.url) since they can't share an identity; the
        # shared hardware tuning lives in modules/services/tcxwave-power-tuning.nix
        # and the shared kiosk session in modules/desktop/dashboard-kiosk.nix.
        metis = mkHost ./hosts/metis/configuration.nix [ ]; # kitchen
        adrastea = mkHost ./hosts/adrastea/configuration.nix [ ]; # office
        amalthea = mkHost ./hosts/amalthea/configuration.nix [ ]; # jupiter-bedroom
        thebe = mkHost ./hosts/thebe/configuration.nix [ ]; # robbie-room

        # Future personal workstations (roaming desktop — same niri + synced
        # $HOME as the laptop). Scaffolded in hosts/ but not registered until the
        # hardware exists, because their REPLACE-ME disks would (intentionally)
        # fail the jupiter.storage assertion at build time. To bring one online:
        # fill in its disk/hostId, uncomment, and add it to the CI build matrix.
        # elara = mkHost ./hosts/elara/configuration.nix [ ];
        # carme = mkHost ./hosts/carme/configuration.nix [ ];
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
        ganymede = {
          hostname = "ganymede";
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.ganymede;
          };
        };
        europa = {
          hostname = "europa";
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.europa;
          };
        };
        callisto = {
          hostname = "callisto";
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.callisto;
          };
        };
        himalia = {
          hostname = "himalia";
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.himalia;
          };
        };
        metis = {
          hostname = "metis";
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.metis;
          };
        };
        adrastea = {
          hostname = "adrastea";
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.adrastea;
          };
        };
        amalthea = {
          hostname = "amalthea";
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.amalthea;
          };
        };
        thebe = {
          hostname = "thebe";
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.thebe;
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
