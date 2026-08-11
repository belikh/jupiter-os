{
  description = "Jupiter OS";

  # Deliberately minimal input set. The previous tree (see the master branch)
  # pulled in chaotic-nyx, jovian, home-manager, deploy-rs, terranix and a
  # private ha-linux-agent flake for every host, which made a clean build
  # effectively impossible (uncached CachyOS kernels, microarch-tuned
  # closures, unfetchable inputs). Each input below is required by amalthea
  # itself; new inputs are added only when the machine that needs them is
  # brought up.
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # Deliberately NOT `inputs.nixpkgs.follows`-ed to the pin above — this
    # tracks nixos-unstable's own moving HEAD so modules/core/crush.nix can
    # take crush from here (fast-moving upstream, want current releases)
    # while every other package stays on the fleet's single pinned nixpkgs
    # commit. Update independently with `nix flake update nixpkgs-unstable`.
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";

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

    # Aeon autonomous agent framework — source for dashboard package (not a flake)
    aeon = {
      url = "github:aeonfun/aeon/main";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      disko,
      impermanence,
      sops-nix,
      ha-linux-agent,
      jovian,
      aeon,
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
            # closures substitutable from cache.nixos.org + Harmonia, untouched by
            # a gaming overlay). The `or` guards handle the hosts that don't
            # import console.nix (so `jupiter.gaming` is absent).
            #
            # mangohud fixup: jovian's overlay backports two MangoHud patches
            # (0805396, 2c1dc528) that nixpkgs has SINCE merged upstream, so
            # applying jovian's overlay to this newer nixpkgs double-applies
            # them and breaks the build ("Reversed or previously applied
            # patch"). Restore stock nixpkgs mangohud — the backports aren't
            # kiosk-critical and stock substitutes from cache.nixos.org. Drop
            # this once jovian upstream removes the now-redundant backports.
            (
              { config, ... }:
              let
                gamingConsole = (config.jupiter.gaming or { }).console or { };
              in
              {
                nixpkgs.overlays = nixpkgs.lib.mkIf (gamingConsole.enable or false) [
                  jovian.overlays.default
                  (_final: _prev: {
                    mangohud = nixpkgs.legacyPackages.x86_64-linux.mangohud;
                  })
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
                # modules/core/crush.nix packages crush itself, pinned
                # straight to a GitHub release tag (nixpkgs' own crush
                # derivation lags upstream releases too much) — but its
                # go.mod requires a newer Go toolchain than this flake's
                # pinned nixpkgs ships. Expose nixpkgs-unstable's `go` alone
                # (not the whole package set) so crush.nix can build against
                # it without floating anything else in the closure.
                (final: prev: {
                  crush-go = nixpkgs-unstable.legacyPackages.${prev.stdenv.hostPlatform.system}.go;
                })
              ];
            }
            hostPath
          ]
          ++ extraModules;
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
      # (gccarch-bdver4-tuned) `pkgs` — see modules/network/pxe-server.nix's
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
      # Embedded script is a STATIC chainload to a fixed URL (europaLanIp +
      # port never change) — it must NOT reference callistoCmdLine/toplevel,
      # or every callisto closure change forces a full iPXE recompile (the
      # cross-compile cost pxe-server.nix's header warns about). The actual
      # per-build kernel cmdline lives in bootIpxeScript below, a plain text
      # file fetched at runtime, so only that (trivial, no-compile) file
      # changes when callisto's closure changes — ipxe.efi/undionly.kpxe
      # build once and stay cached indefinitely.
      chainScript = untunedPkgs.writeText "chain.ipxe" ''
        #!ipxe
        chain http://${europaLanIp}:${toString europaPxeHttpPort}/boot.ipxe
      '';
      ipxeBoot = untunedPkgs.ipxe.override { embedScript = chainScript; };
      bootIpxeScript = untunedPkgs.writeText "boot.ipxe" ''
        #!ipxe
        kernel http://${europaLanIp}:${toString europaPxeHttpPort}/bzImage ${callistoCmdLine}
        initrd http://${europaLanIp}:${toString europaPxeHttpPort}/initrd
        boot
      '';
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
          name = "boot.ipxe";
          path = bootIpxeScript;
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
        # switches to a bdver4-tuned closure served from Harmonia.
        # Also runs the PXE server for callisto (see
        # hosts/europa/configuration.nix) — ganymede's role in the old design,
        # moved here since ganymede isn't registered yet.
        europa = mkHost ./hosts/europa/configuration.nix [ pxeModule ]; # NAS + data hub

        # No-local-disk compute node, PXE-booted from europa with root over
        # iSCSI (europa's tank/services/callisto-root zvol) — the fleet's
        # shared Nix remote builder (i5, 64GB RAM). See
        # hosts/callisto/configuration.nix and
        # docs/callisto-iscsi-root-provisioning.md (live at 10.1.1.3, root
        # over ext4-iSCSI on europa's zvol).
        callisto = mkHost ./hosts/callisto/configuration.nix [ ];

        # Kamatera VPS (persistent, disk-booted; not a fleet member — built
        # standalone, not via mkHost). The raw disk image is built with nixpkgs'
        # make-disk-image.nix (see hosts/pallene/disk-configuration.nix),
        # compressed, and served for Kamatera's "Import from URL" flow.
        pallene = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [ ./hosts/pallene/disk-configuration.nix ];
        };
      };

      # Build the raw 10 GB disk image for Kamatera:
      #   nix build .#pallene-raw
      # The output is result/nixos.img — compress with `xz -T0 -9` before serving.
      packages.x86_64-linux.pallene-raw = self.nixosConfigurations.pallene.config.system.build.raw;

      # The TFTP root europa serves callisto's netboot chain from — exposed
      # standalone (built with the untuned nixpkgs, see pxeModule above) so
      # it's independently checkable without pulling in europa's whole
      # (gccarch-bdver4-tuned) system closure.
      packages.x86_64-linux.pxe-tftproot = pxeTftpRoot;

      # Aeon dashboard and CLI packages — built from upstream aeonfun/aeon main branch
      # (not a flake, so we use fetchFromGitHub + buildNpmPackage)
      packages.x86_64-linux.aeon-dashboard =
        (import ./pkgs/aeon/default.nix {
          lib = nixpkgs.lib;
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          fetchFromGitHub = nixpkgs.legacyPackages.x86_64-linux.fetchFromGitHub;
          stdenv = nixpkgs.legacyPackages.x86_64-linux.stdenv;
          buildNpmPackage = nixpkgs.legacyPackages.x86_64-linux.buildNpmPackage;
          nodejs = nixpkgs.legacyPackages.x86_64-linux.nodejs;
          makeWrapper = nixpkgs.legacyPackages.x86_64-linux.makeWrapper;
        }).aeon-dashboard;
      packages.x86_64-linux.aeon-cli =
        (import ./pkgs/aeon/default.nix {
          lib = nixpkgs.lib;
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          fetchFromGitHub = nixpkgs.legacyPackages.x86_64-linux.fetchFromGitHub;
          stdenv = nixpkgs.legacyPackages.x86_64-linux.stdenv;
          buildNpmPackage = nixpkgs.legacyPackages.x86_64-linux.buildNpmPackage;
          nodejs = nixpkgs.legacyPackages.x86_64-linux.nodejs;
          makeWrapper = nixpkgs.legacyPackages.x86_64-linux.makeWrapper;
        }).aeon-cli;

      # suno-backup — Go daemon that mirrors a Suno account's WAV masters +
      # the complete per-clip metadata into europa's tank/archive/suno dataset.
      # Built from in-tree stdlib-only source. Exposed standalone so the
      # vendorHash can be recomputed via `nix build .#suno-backup` without
      # pulling europa's whole bdver4-tuned closure. Consumed by the host via
      # modules/services/suno-backup.nix's pkgs.callPackage.
      packages.x86_64-linux.suno-backup = (
        import ./pkgs/suno-backup {
          lib = nixpkgs.lib;
          buildGoModule = nixpkgs.legacyPackages.x86_64-linux.buildGoModule;
        }
      );

      # `nix flake check` builds every registered host closure — for a
      # single-host bootstrap that's cheap, and it's the whole point: prove
      # the thing builds.
      checks.x86_64-linux = builtins.mapAttrs (
        _: host: host.config.system.build.toplevel
      ) self.nixosConfigurations;

      # Documentation site: auto-generated from all jupiter.* modules
      # Uses an existing host configuration (amalthea) which already has all
      # modules properly imported and evaluated with correct defaults.
      docs =
        let
          # Get the options from the amalthea host configuration
          # This includes all jupiter.* options plus all NixOS base options
          eval = self.nixosConfigurations.amalthea;
          optionsDoc = untunedPkgs.nixosOptionsDoc { options = eval.options; };
          allOptionsMarkdown = optionsDoc.optionsCommonMark;
          lib = untunedPkgs.lib;
          modulesDir = ./modules;
          # Get subdirectories of modules/ (these are the categories), exclude files
          categoryDirs = builtins.filter (
            d: builtins.pathExists (modulesDir + "/${d}") && !lib.strings.hasSuffix ".nix" d
          ) (builtins.attrNames (builtins.readDir modulesDir));
          # Generate timestamp and commit at build time via shell
          timestamp = "";
          commit = "";
        in
        untunedPkgs.stdenv.mkDerivation {
          name = "jupiter-os-docs";
          src = ./.;
          nativeBuildInputs = [ untunedPkgs.mdbook ];
          buildPhase = ''
                      mkdir -p src

                      # book.toml
                      cat > book.toml <<'BOOK_EOF'
            [book]
            title = "Jupiter OS — Module Reference"
            description = "Auto-generated documentation for all jupiter.* NixOS modules"
            authors = ["Jupiter OS Maintainers"]
            src = "src"
            language = "en"

            [build]
            build-dir = "book"

            [output.html]
            default-theme = "light"
            preferred-dark-theme = "dark"
            curly-quotes = true
            mathjax = false
            additional-css = []
            additional-js = []
            fold = { enable = true, level = 2 }
            site-url = "https://belikh.github.io/jupiter-os/"
            git-repository-url = "https://github.com/belikh/jupiter-os/"
            edit-url-template = "https://github.com/belikh/jupiter-os/edit/main/{path}"

            [output.html.favicon]
            # Use the Fallout splash icon if available
            BOOK_EOF

                      # index.md — landing page
                      cat > src/index.md <<'INDEX_EOF'
            # Jupiter OS Module Reference

            Welcome to the auto-generated reference for all **jupiter.\*** NixOS modules in the Jupiter OS fleet.

            > **Jupiter OS** is a declarative, ZFS-backed NixOS monorepo for the Jupiter home/lab infrastructure — currently 7 registered hosts (4 TCx Wave dashboard kiosks, 1 ZFS NAS, 1 build server, 1 VPS builder), rebuilt from scratch one machine at a time.

            ---

            ## Quick Links

            - **Repository**: [github.com/belikh/jupiter-os](https://github.com/belikh/jupiter-os)
            - **Fleet Status**: See `STATUS` table in [CLAUDE.md](https://github.com/belikh/jupiter-os/blob/main/CLAUDE.md)
            - **Architecture**: [jupiterOS domain reference](references/domains/jupiterOS.md)

            ---

            ## Module Categories

            Each category below contains modules that define `jupiter.<category>.*` options. Browse the full options reference on the **Options Reference** page.

            INDEX_EOF

                      # Add category links to index.md
                      for cat in ${toString categoryDirs}; do
                        echo "- [$cat](options.html)" >> src/index.md
                      done

                      # Generate timestamp and commit for the landing page
                      timestamp=$(date -u +"%Y-%m-%d %H:%M UTC")
                      commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

                      cat >> src/index.md <<INDEX_EOF2

            ---

            ## Generation Info

            - **Generated from**: \`flake.nix\` \`docs\` package
            - **Toolchain**: \`nixosOptionsDoc\` + \`mdBook\`
            - **Last updated**: $timestamp
            - **Commit**: $commit

            > This documentation is regenerated on every push to \`main\` via GitHub Actions.
            INDEX_EOF2

                      # SUMMARY.md - single options reference page with folded sections
                      cat > src/SUMMARY.md <<'SUMMARY_EOF'
            - [Overview](index.md)
            - [Options Reference](options.md)
            SUMMARY_EOF

                      # Copy the generated CommonMark to src/
                      cp ${allOptionsMarkdown} src/options.md

                      # Build the site
                      mdbook build
          '';
          installPhase = ''
            mkdir -p $out
            cp -r book/* $out/
          '';
        };

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
