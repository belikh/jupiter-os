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
                # jupiter.gaming.console, but injected everywhere so any machine
                # can attach the gaming profile (see modules/gaming/console.nix).
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

      # Wrap deploy-rs's standard NixOS activation with a post-switch health
      # check. `switch-to-configuration switch` returning 0 only proves the
      # activation script ran — not that the resulting generation is actually
      # healthy. deploy-rs treats a non-zero activation exit the same as a
      # broken SSH reconnect: it auto-reverts to the previous generation
      # (`autoRollback`, on by default) within `activationTimeout` (240s
      # default). Adding this check is what makes `autoRollback` catch "came
      # up but didn't reach multi-user" instead of just "network died mid
      # deploy" — the gap flagged in docs/roadmap.md's operational-maturity
      # section, and the precondition for unattended auto-deploy below.
      deployActivate =
        cfg:
        (
          deploy-rs.lib.x86_64-linux.activate.custom
          // {
            dryActivate = "$PROFILE/bin/switch-to-configuration dry-activate";
            boot = "$PROFILE/bin/switch-to-configuration boot";
          }
        )
          cfg.config.system.build.toplevel
          ''
            # work around https://github.com/NixOS/nixpkgs/issues/73404
            cd /tmp

            $PROFILE/bin/switch-to-configuration switch

            # https://github.com/serokell/deploy-rs/issues/31
            ${
              with cfg.config.boot.loader;
              nixpkgs.lib.optionalString systemd-boot.enable "sed -i '/^default /d' ${efi.efiSysMountPoint}/loader/loader.conf"
            }

            # Fail (triggering deploy-rs's auto-rollback) if the new
            # generation doesn't reach a running system within 2 minutes.
            if ! timeout 120 sh -c 'until [ "$(systemctl is-system-running 2>/dev/null)" = running ] || [ "$(systemctl is-system-running 2>/dev/null)" = degraded ]; do sleep 2; done'; then
              echo "deploy-rs: system did not reach running/degraded state within 120s" >&2
              exit 1
            fi
          '';

      # The NAS (europa) auto-derives its syncoid replication sources from
      # every OTHER host's jupiter.backup declaration — so adding a host that
      # holds state wires up central backup with no edit here. Same
      # cross-host-via-closure pattern as pxeModule above. (Reading other
      # hosts' config is acyclic: they never read europa's config.)
      site = import ./lib/site.nix;
      # Non-fleet hosts (never deployed, no persistent state to back up) don't
      # import modules/storage/backup.nix at all, so jupiter.backup wouldn't
      # even be a defined option on them — excluded here rather than given a
      # no-op import just to satisfy this scan.
      nonFleetHosts = [
        site.backupHub.host
        "pallene"
      ];
      backupHubModule =
        { lib, ... }:
        let
          otherHosts = lib.filterAttrs (
            name: _: !(builtins.elem name nonFleetHosts)
          ) self.nixosConfigurations;
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
        # $HOME as the laptop). Their disk is still a REPLACE-ME placeholder
        # (no hardware yet) — that's just a build-time warning (see
        # modules/storage/zfs-profiles.nix), not a CI failure, until someone
        # fills it in per the bring-online steps in each host's
        # configuration.nix — registering them now (rather than leaving them
        # as unwired scaffolds) is what gets them CI coverage already.
        elara = mkHost ./hosts/elara/configuration.nix [ ];
        carme = mkHost ./hosts/carme/configuration.nix [ ];

        # Ephemeral BinaryLane "rebuild the world" build server — see
        # docs/roadmap.md and hosts/pallene/configuration.nix. NOT a fleet
        # member: deliberately absent from ci.yml's build-and-boot-test
        # matrix and from deploy.nodes below — it's never deployed to, only
        # turned into an ISO (see the `pallene-iso` package output).
        pallene = mkHost ./hosts/pallene/configuration.nix [ ];
      };

      packages.x86_64-linux =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;

          # `jupiter.*` options reference, rendered via nixos-render-docs.
          # `.optionsCommonMark` is the markdown backing `docs/module-options.md`
          # (see `make docs-modules`); `.optionsJSON` is the structured form,
          # for tooling that wants it instead of parsing markdown.
          moduleOptionsDoc = import ./lib/module-options.nix {
            inherit pkgs;
            inherit (pkgs) lib;
            nixpkgsLib = nixpkgs.lib;
            sopsNixModule = sops-nix.nixosModules.sops;
            impermanenceModule = impermanence.nixosModules.impermanence;
            diskoModule = disko.nixosModules.disko;
            jovianModule = jovian.nixosModules.default;
            chaoticModule = chaotic.nixosModules.default;
            homeManagerModule = home-manager.nixosModules.home-manager;
            haLinuxAgentModule = ha-linux-agent.nixosModules.default;
          };
        in
        {
          module-options-md = moduleOptionsDoc.optionsCommonMark;
          module-options-json = moduleOptionsDoc.optionsJSON;

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

          # ISO for the ephemeral BinaryLane build server (see
          # hosts/pallene/configuration.nix, docs/roadmap.md). Build with
          # `make pallene-iso`, not plain `nix build` — that target injects
          # the BinaryLane API + attic push tokens the same way
          # `make build-mx4300` injects OpenWrt secrets.
          pallene-iso = self.nixosConfigurations.pallene.config.system.build.isoImage;
        };

      # Deployment configuration for deploy-rs
      deploy.nodes = {
        ganymede = {
          hostname = "ganymede";
          profiles.system = {
            user = "root";
            path = deployActivate self.nixosConfigurations.ganymede;
          };
        };
        europa = {
          hostname = "europa";
          profiles.system = {
            user = "root";
            path = deployActivate self.nixosConfigurations.europa;
          };
        };
        callisto = {
          hostname = "callisto";
          profiles.system = {
            user = "root";
            path = deployActivate self.nixosConfigurations.callisto;
          };
        };
        himalia = {
          hostname = "himalia";
          profiles.system = {
            user = "root";
            path = deployActivate self.nixosConfigurations.himalia;
          };
        };
        metis = {
          hostname = "metis";
          profiles.system = {
            user = "root";
            path = deployActivate self.nixosConfigurations.metis;
          };
        };
        adrastea = {
          hostname = "adrastea";
          profiles.system = {
            user = "root";
            path = deployActivate self.nixosConfigurations.adrastea;
          };
        };
        amalthea = {
          hostname = "amalthea";
          profiles.system = {
            user = "root";
            path = deployActivate self.nixosConfigurations.amalthea;
          };
        };
        thebe = {
          hostname = "thebe";
          profiles.system = {
            user = "root";
            path = deployActivate self.nixosConfigurations.thebe;
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
