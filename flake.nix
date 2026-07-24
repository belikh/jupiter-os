{
  description = "Jupiter OS - NixOS monorepo (bootstrap rebuild, starting from amalthea)";

  # Deliberately minimal input set. The previous tree (see the master branch)
  # pulled in chaotic-nyx, jovian, home-manager, deploy-rs, terranix and a
  # private ha-linux-agent flake for every host, which made a clean build
  # effectively impossible (uncached CachyOS kernels, microarch-tuned
  # closures, unfetchable inputs). Each input below is required by amalthea
  # itself; new inputs are added only when the machine that needs them is
  # brought up.
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Declarative partitioning (ZFS-on-root layouts in modules/storage/zfs-profiles.nix)
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Erase-your-darlings root (modules/core/impermanence.nix)
    impermanence = {
      url = "github:nix-community/impermanence";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Secrets management (sops + age)
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Home Assistant companion agent
    ha-linux-agent = {
      url = "github:belikh/ha-linux-agent";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # SteamOS-style gaming stack (gamescope "gaming mode" session, Steam Deck
    # quirks, gamescope cap_sys_nice wrapper). Pulled in by the TCx Wave kiosks'
    # dashboard-gaming mode (modules/gaming/console.nix). Its nixos module is
    # imported fleet-wide (inert until jovian.steam.* is enabled); its overlay
    # is applied only on hosts that enable jupiter.gaming.console, so the
    # jovian-provided packages don't perturb europa/callisto's closures.
    #
    # NOTE: chaotic-nyx was evaluated and DROPPED. Forcing it to follow this
    # flake's nixpkgs (the repo convention) caused patch skew — chaotic's
    # mangohud override reapplied a patch nixpkgs already ships, breaking the
    # whole gaming closure's build. jovian alone covers the stack the kiosks
    # need; chaotic's only ungated extras (proton-cachyos, gamescope_git) are
    # dispensable (Steam ships Proton; jovian provides gamescope). Re-add only
    # if a host genuinely needs a chaotic-only package, and don't force follows.
    jovian = {
      url = "github:Jovian-Experiments/Jovian-NixOS";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      impermanence,
      sops-nix,
      ha-linux-agent,
      jovian,
      ...
    }:
    let
      # Inject flake-provided modules via a lexical closure rather than
      # specialArgs, so host files stay plain NixOS modules. extraModules
      # lets a specific host pick up something only computable here (e.g.
      # europa's pxeModule below, which reads another host's build output) —
      # `[ ]` for every host that doesn't need one.
      mkHost =
        hostPath: extraModules:
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            (
              { ... }:
              {
                imports = [
                  sops-nix.nixosModules.sops
                  impermanence.nixosModules.impermanence
                  disko.nixosModules.disko
                  ha-linux-agent.nixosModules.default
                  # jovian's nixos module is inert unless jovian.steam.* is
                  # enabled, so importing it fleet-wide is free (just option
                  # definitions). The jovian + chaotic OVERLAYS, by contrast,
                  # would perturb every host's pkgs — they're applied only on
                  # hosts that opt into the gaming stack below.
                  jovian.nixosModules.default
                ];
              }
            )
            # On hosts that enable jupiter.gaming.console, make jovian's
            # packages resolvable (gamescope-session, steamos-manager, …) by
            # applying its overlay to this host's pkgs. Gated so
            # europa/callisto/pallene never see it (buildability: keep their
            # closures substitutable from cache.nixos.org + attic, untouched by
            # a gaming overlay). The `or` guards handle the hosts that don't
            # import console.nix (so `jupiter.gaming` is absent).
            (
              { config, ... }:
              let
                gamingConsole = (config.jupiter.gaming or { }).console or { };
              in
              {
                nixpkgs.overlays = nixpkgs.lib.mkIf (gamingConsole.enable or false) [
                  jovian.overlays.default
                ];
              }
            )
            # bmake's `deptgt-interrupt` unit test is flaky under load: it sends
            # SIGINT to a child make and expects exit 130, but under the heavy
            # oversubscription of a "rebuild the world" run (load 8-21) the
            # signal sometimes doesn't land in time and the child exits 0 ->
            # "Failed tests: deptgt-interrupt" -> bmake build fails -> lowdown
            # (uses bmake) fails -> cascades up to the europa system toplevel.
            # bmake itself builds fine; only its test suite is the problem, so
            # skip it. See europa-20260716120909.log in R2 logs/.
            #
            # perl5Packages.Test2Harness's `t/integration/preload.t` is
            # likewise flaky under heavy distributed-build load: it failed
            # attempt11 and attempt12 of the europa bring-up (same "1 of 62
            # test files failed" signature both times), cascading through
            # nix-perl -> nix -> the whole system toplevel. The other 61
            # test files and 1729 assertions pass; only this one subtest
            # under load is the problem, so skip the test suite entirely.
            {
              nixpkgs.overlays = [
                (final: prev: {
                  bmake = prev.bmake.overrideAttrs (_: {
                    doCheck = false;
                  });
                  perl5Packages = prev.perl5Packages // {
                    Test2Harness = prev.perl5Packages.Test2Harness.overrideAttrs (_: {
                      doCheck = false;
                    });
                  };
                })
              ];
            }
            hostPath
          ]
          ++ extraModules;
        };

      # Ephemeral build-server ISO host (pallene): no common flake-module
      # injection — it's an installer ISO with no persistent host key, no
      # storage profile, no impermanence. Secrets are baked in at ISO build
      # time, not decrypted at runtime.
      mkIsoHost =
        hostPath:
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [ hostPath ];
        };

      # Wire the PXE server (on europa — see hosts/europa/configuration.nix
      # for why it's here and not ganymede) directly to callisto's build
      # products, so the TFTP-served image always matches the flake. The
      # cmdLine's `init=` points the booting kernel at its closure's init —
      # this is the standard switch_root target on every NixOS boot path
      # (disk, netboot, or iSCSI-root alike), not a kexec-specific trick:
      # once stage-1 finds and mounts the real root (over iSCSI now, see
      # hosts/callisto/configuration.nix), it switch_roots into whatever
      # init= names.
      #
      # Built with the PLAIN untuned nixpkgs.legacyPackages, not europa's own
      # (gccarch-btver2-tuned) `pkgs` — see modules/network/pxe-server.nix's
      # comment for why that distinction is load-bearing here.
      untunedPkgs = nixpkgs.legacyPackages.x86_64-linux;

      callistoConfig = self.nixosConfigurations.callisto.config;
      callistoBuild = callistoConfig.system.build;
      # `ip=dhcp`: belt-and-suspenders for the classic (non-systemd) stage-1
      # initrd's DHCP client — boot.iscsi-initiator forces
      # boot.initrd.network.enable = true (see hosts/callisto/configuration.nix),
      # which brings up initrd networking generically, but doesn't itself
      # guarantee DHCP fires with no explicit `ip=` kernel param. iSCSI
      # login can't reach the portal without an address first, so this is
      # cheap insurance rather than an assumption.
      callistoCmdLine = "init=${callistoBuild.toplevel}/init loglevel=4 ip=dhcp ${toString callistoConfig.boot.kernelParams}";
      europaLanIp = "10.1.1.2";
      europaPxeHttpPort = 8082; # keep in sync with jupiter.pxe.httpPort default
      ipxeScript = untunedPkgs.writeText "netboot.ipxe" ''
        #!ipxe
        kernel http://${europaLanIp}:${toString europaPxeHttpPort}/bzImage ${callistoCmdLine}
        initrd http://${europaLanIp}:${toString europaPxeHttpPort}/initrd
        boot
      '';
      ipxeBoot = untunedPkgs.ipxe.override { embedScript = ipxeScript; };
      pxeTftpRoot = untunedPkgs.linkFarm "pxe-tftproot" [
        {
          name = "ipxe.efi";
          path = "${ipxeBoot}/ipxe.efi";
        }
        {
          name = "undionly.kpxe";
          path = "${ipxeBoot}/undionly.kpxe";
        }
        {
          name = "bzImage";
          path = "${callistoBuild.kernel}/bzImage";
        }
        {
          name = "initrd";
          path = "${callistoBuild.initialRamdisk}/initrd";
        }
      ];
      pxeModule = { ... }: {
        jupiter.pxe = {
          enable = true;
          root = pxeTftpRoot;
          httpPort = europaPxeHttpPort;
        };
      };
    in
    {
      nixosConfigurations = {
        # TCx Wave dashboard kiosks — 4 identical units, one per room. Each is
        # its own host (own hostName/hostId/dashboard URL) since they can't
        # share an identity; the shared hardware tuning lives in
        # modules/services/tcxwave-power-tuning.nix and the shared kiosk
        # session in modules/desktop/dashboard-kiosk.nix. amalthea is the
        # bootstrap host and the canonical template; the others are clones.
        amalthea = mkHost ./hosts/amalthea/configuration.nix [ ]; # jupiter-bedroom
        metis = mkHost ./hosts/metis/configuration.nix [ ]; # kitchen
        adrastea = mkHost ./hosts/adrastea/configuration.nix [ ]; # office
        thebe = mkHost ./hosts/thebe/configuration.nix [ ]; # robbie-room

        # HPE MicroServer Gen10 — the ZFS NAS and data hub. Phase 1 untuned
        # bootstrap from cache.nixos.org (stock kernel, no microarch); Phase 2
        # switches to a btver2-tuned closure served from its own Attic cache.
        # Also runs the PXE server for callisto (see
        # hosts/europa/configuration.nix) — ganymede's role in the old design,
        # moved here since ganymede isn't registered yet.
        europa = mkHost ./hosts/europa/configuration.nix [ pxeModule ]; # NAS + data hub

        # No-local-disk compute node, PXE-booted from europa with root over
        # iSCSI (europa's tank/services/callisto-root zvol) — the fleet's
        # shared Nix remote builder (i5, 64GB RAM). See
        # hosts/callisto/configuration.nix and
        # docs/callisto-iscsi-root-provisioning.md; not yet physically
        # provisioned/booted on this design.
        callisto = mkHost ./hosts/callisto/configuration.nix [ ];

        # Ephemeral BinaryLane build server. Never a persistent fleet member —
        # booted from the pallene-iso package, rebuilds europa's tuned closure,
        # pushes to attic, self-destructs. See hosts/pallene/configuration.nix
        # and modules/services/build-server.nix.
        pallene = mkIsoHost ./hosts/pallene/configuration.nix; # build server
      };

      # The disposable build server as a bootable ISO. Build with
      # `make pallene-iso` (not plain `nix build .#pallene-iso`) — that target
      # injects the BinaryLane API + attic push tokens the same way
      # `make build-mx4300` injects OpenWrt secrets, then cleans up.
      packages.x86_64-linux.pallene-iso = self.nixosConfigurations.pallene.config.system.build.isoImage;

      # The TFTP root europa serves callisto's netboot chain from — exposed
      # standalone (built with the untuned nixpkgs, see pxeModule above) so
      # it's independently checkable without pulling in europa's whole
      # (gccarch-btver2-tuned) system closure.
      packages.x86_64-linux.pxe-tftproot = pxeTftpRoot;

      # `nix flake check` builds every registered host closure — for a
      # single-host bootstrap that's cheap, and it's the whole point: prove
      # the thing builds.
      checks.x86_64-linux = builtins.mapAttrs (
        _: host: host.config.system.build.toplevel
      ) self.nixosConfigurations;

      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-rfc-style;

      devShells.x86_64-linux.default =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
        in
        pkgs.mkShell {
          packages = with pkgs; [
            sops
            age
            ssh-to-age
            nixfmt-rfc-style
          ];
        };
    };
}
