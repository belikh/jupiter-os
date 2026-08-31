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

    # suno-web — browser UI over the Suno archive europa mirrors (search,
    # metadata filters, persona browsing, the clip derivation graph,
    # playlists, playback). Justified by a registered host that uses it:
    # europa enables jupiter.services.sunoWeb. Lives in its own repository
    # rather than in-tree because it is a general-purpose browser for any
    # Suno archive, not fleet-specific config; jupiter-os keeps only the
    # service module (modules/services/suno-web.nix) that wires it into a
    # host. Stdlib-only Go, so it substitutes clean on europa's bdver4-tuned
    # closure.
    suno-web = {
      url = "github:belikh/suno-web";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # OpenDesign — local-first design product (daemon `od` + Next.js web
    # frontend). Provides a NixOS module (services.open-design) and
    # packages for daemon/web. Justified by a registered host that uses
    # it: callisto enables jupiter.services.openDesign. Design artefacts
    # are generated as real files (HTML/PDF/PPTX/MP4) via agent skills;
    # the web frontend proxies /api/* to the daemon and serves the static
    # SPA. Enabled on the serving host alongside dsh/opencode-web.
    open-design = {
      url = "github:nexu-io/open-design";
      inputs.nixpkgs.follows = "nixpkgs";
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
      suno-web,
      open-design,
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
                  # OpenDesign daemon + web frontend (services.open-design).
                  # Imported fleet-wide (inert until services.open-design.enable
                  # or jupiter.services.openDesign.enable is set), so every host
                  # can opt in without a per-host flake import.
                  open-design.nixosModules.default
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
            # REMOVED 2026-08-13: a fleet-wide overlay that rewrote
            # stdenv.mkDerivation to force doCheck/doInstallCheck = false on
            # EVERY derivation. Do not re-add it.
            #
            # doCheck is part of the derivation, so forcing it changed the
            # output hash of every package nixpkgs ships with doCheck = true,
            # and of everything downstream of those — which is nearly the whole
            # closure, since zlib is one of them. cache.nixos.org has the
            # upstream hashes and never had ours. Isolated at the same locked
            # nixpkgs rev, with the overlay as the only variable:
            #
            #   plain nixpkgs zlib : /nix/store/fkcbg2c1w29jr5yp9awai9w3v1wvxdk9-zlib-1.3.2
            #   + this overlay     : /nix/store/06jg037flvplksig8n08infallylhlhq-zlib-1.3.2
            #
            # Measured on europa's toplevel (`nix build --dry-run`), overlay
            # present vs absent, nothing else changed:
            #
            #   with    2244 derivations to build, 1942 paths to fetch (9.9 GiB)
            #   without   70 derivations to build,  896 paths to fetch (2.4 GiB)
            #
            # So it took the ENTIRE fleet off cache.nixos.org — including the
            # 7.6GB kiosks, which OOM on heavy local builds, and it is why the
            # CI→Harmonia push was load-bearing for untuned hosts too.
            #
            # It began as one-off overrides for genuinely flaky checkPhases
            # (bmake's `deptgt-interrupt` racing a SIGINT under load;
            # perl5Packages.Test2Harness's `t/integration/preload.t`; zlib's
            # ./minigzip64 taking SIGILL when CI built gccarch-tuned code on
            # heterogeneous Azure runners and then EXECUTED it) and got
            # generalised. Generalising inverted it: a package that substitutes
            # from cache.nixos.org never runs its checkPhase locally at all, so
            # the overlay was itself the cause of the local rebuilds whose
            # flaky tests it existed to suppress.
            #
            # If a specific package flakes again, override that package —
            # `bmake = prev.bmake.overrideAttrs { doCheck = false; };` — which
            # costs one package's cache hit instead of all of them. The SIGILL
            # case additionally requires microarch tuning to be on; it is
            # currently off for europa and callisto.
            {
              nixpkgs.overlays = [
                # modules/core/crush.nix packages crush itself, pinned
                # straight to a GitHub release tag (nixpkgs' own crush
                # derivation lags upstream releases too much) — but its
                # go.mod requires a newer Go toolchain than this flake's
                # pinned nixpkgs ships. Expose nixpkgs-unstable's `go` alone
                # (not the whole package set) so crush.nix can build against
                # it without floating anything else in the closure.
                (final: prev: {
                  crush-go = nixpkgs-unstable.legacyPackages.${prev.stdenv.hostPlatform.system}.go;
                  # The flake rev, fleet-wide (arcade remediation W4a):
                  # modules/services/arcade-webapp.nix stamps it into the
                  # webapp's version so a live binary identifies its tree
                  # ("a static 0.1.0 cannot identify what is live" —
                  # plan §6.F). An overlay attr is the one lexically
                  # available place every host's pkgs can see it.
                  jupiter-flake-rev = self.rev or "";
                })
              ];
            }
            hostPath
          ]
          ++ extraModules;
        };

      # The PXE server lives on europa (see hosts/europa/configuration.nix for
      # why it's here and not ganymede), but europa's system closure must NOT
      # reference callisto's. Building/evaluating europa used to drag
      # callisto's entire (skylake-tuned) kernel + initrd + toplevel in
      # through the TFTP root; the netboot chain is therefore split in two:
      #
      #   pxeTftpRoot        — ipxe.efi + undionly.kpxe. Static, callisto-free,
      #                        lives IN europa's closure, served over TFTP.
      #   pxeNetbootAssets   — boot.ipxe + bzImage + initrd. Derived from
      #                        callisto, deliberately NOT in europa's closure;
      #                        published out-of-band into jupiter.pxe.assetsDir
      #                        (see modules/network/pxe-server.nix) and served
      #                        over HTTP.
      #
      # The cmdLine's `init=` points the booting kernel at its closure's init —
      # this is the standard switch_root target on every NixOS boot path
      # (disk, netboot, or iSCSI-root alike), not a kexec-specific trick:
      # once stage-1 finds and mounts the real root (over iSCSI now, see
      # hosts/callisto/configuration.nix), it switch_roots into whatever
      # init= names. It is kept (rather than letting stage-1 default to
      # /nix/var/nix/profiles/system/init) precisely because it pins the
      # served kernel/initrd and the userland they boot to ONE generation —
      # which is also why the assets must be published AFTER callisto has
      # switched to that generation, so the path exists on callisto's own
      # iSCSI root. See docs/callisto-iscsi-root-provisioning.md.
      #
      # Built with the PLAIN untuned nixpkgs.legacyPackages, not europa's own
      # (gccarch-x86-64-v3-tuned) `pkgs` — see modules/network/pxe-server.nix's
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
      # Keep in sync with modules/network/fleet.nix's
      # jupiter.fleet.addresses.europa (this is flake-output scope, before any
      # NixOS module exists to read the option from).
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
      # TFTP root: the chainload binaries only. Nothing here reaches callisto,
      # so europa's closure stays callisto-free — verify with
      #   nix why-depends --derivation \
      #     .#nixosConfigurations.europa.config.system.build.toplevel \
      #     .#nixosConfigurations.callisto.config.system.build.toplevel
      pxeTftpRoot = untunedPkgs.linkFarm "pxe-tftproot" [
        {
          name = "ipxe.efi";
          path = "${ipxeBoot}/ipxe.efi";
        }
        {
          name = "undionly.kpxe";
          path = "${ipxeBoot}/undionly.kpxe";
        }
      ];
      # HTTP-served half — the callisto-derived files. Published into
      # jupiter.pxe.assetsDir by jupiter-pxe-assets.service, NOT wired into
      # any host's config: a store-path reference from europa is exactly the
      # coupling this split exists to remove.
      pxeNetbootAssets = untunedPkgs.linkFarm "pxe-netboot-assets" [
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

      # Hand europa the suno-web package from the flake input. Same lexical
      # closure pattern as pxeModule above: modules/services/suno-web.nix
      # declares a `package` option and stays a plain NixOS module, and the
      # input never leaks into hosts that don't use it.
      sunoWebModule = { ... }: {
        jupiter.services.sunoWeb.package = suno-web.packages.x86_64-linux.suno-web;
      };

      # OpenDesign daemon rebuilt with Node 22 to avoid better_sqlite3 12.10.0
      # crash on Node 24.19 (RemoveEnvironmentCleanupHook: env != nullptr).
      # Upstream builds with nodejs_24 (v137) but better_sqlite3 12.10.0 only
      # has prebuilds up to v131 (Node 22); its from-source build on 24.19
      # triggers the V8 API bug. Node 22 is LTS and has v127 prebuilds.
      # This module pins services.open-design.package to the Node-22 rebuild
      # so callisto's daemon is stable even with Design Harness (od-next)
      # active. Web frontend stays on Node 24 (no native binding).
      openDesignDaemonNode22Module = { config, pkgs, lib, ... }: {
        services.open-design.package = pkgs.callPackage ./pkgs/open-design-daemon {
          inherit (pkgs) lib stdenv fetchPnpmDeps pnpmConfigHook makeWrapper python3 gnumake pkg-config;
          nodejs_22 = pkgs.nodejs_22;
          pnpm_10 = pkgs.pnpm_10;
          open-design = open-design;
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
        europa = mkHost ./hosts/europa/configuration.nix [
          pxeModule
          sunoWebModule
        ]; # NAS + data hub

        # No-local-disk compute node, PXE-booted from europa with root over
        # iSCSI (europa's tank/services/callisto-root zvol) — the fleet's
        # shared Nix remote builder (i5, 64GB RAM). See
        # hosts/callisto/configuration.nix and
        # docs/callisto-iscsi-root-provisioning.md (live at 10.1.1.3, root
        # over ext4-iSCSI on europa's zvol).
        callisto = mkHost ./hosts/callisto/configuration.nix [
          openDesignDaemonNode22Module
        ];

        # Arcade webapp pipeline TEST host — a minimal VM (tests/hosts/
        # arcade-webapp-vm.nix) running the real
        # modules/services/arcade-webapp.nix against the deterministic
        # fixture corpus, with in-VM smoke assertions. Not a fleet machine:
        # no common.nix, no sops. Driven by `make test-arcade-webapp`
        # (scripts/test-arcade-webapp.sh); registered here so
        # `nixos-rebuild build-vm` / the driver can reach it (and `make
        # check` proves it evaluates).
        arcade-webapp-vm = mkHost ./tests/hosts/arcade-webapp-vm.nix [ ];

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

      # The TFTP half of the netboot chain (ipxe.efi + undionly.kpxe) — the
      # part that lives in europa's closure. Exposed standalone (built with
      # the untuned nixpkgs, see pxeModule above) so it's independently
      # checkable without pulling in europa's whole (gccarch-x86-64-v3-tuned)
      # system closure. Contains NO callisto build products since the split;
      # those are pxe-netboot-assets below.
      packages.x86_64-linux.pxe-tftproot = pxeTftpRoot;

      # The HTTP half: boot.ipxe + callisto's bzImage/initrd. Deliberately a
      # standalone package rather than part of europa's system closure, so
      # building europa never builds callisto. europa publishes it with
      #   systemctl start jupiter-pxe-assets.service
      # (jupiter.pxe.assetsFlakeRef points at this attr) — run that AFTER
      # callisto has switched to the generation being served, since boot.ipxe
      # pins `init=` to that toplevel and the path has to exist on callisto's
      # own iSCSI root. v3-tagged: only substitutes/builds where
      # gccarch-x86-64-v3 is available.
      packages.x86_64-linux.pxe-netboot-assets = pxeNetbootAssets;

      # dsh — DeepSeek Harness CLI + web UI (see pkgs/dsh). Built from the
      # published npm tarball with a generated prod-only lockfile; exposed
      # standalone (untuned legacyPackages, like nom-web) so the npm
      # lock hash can be recomputed via `nix build .#dsh` without pulling
      # callisto's whole skylake-tuned closure. Consumed by the host via
      # modules/services/dsh.nix's pkgs.callPackage.
      packages.x86_64-linux.dsh = (
        import ./pkgs/dsh {
          lib = nixpkgs.lib;
          buildNpmPackage = nixpkgs.legacyPackages.x86_64-linux.buildNpmPackage;
          nodejs = nixpkgs.legacyPackages.x86_64-linux.nodejs;
          fetchurl = nixpkgs.legacyPackages.x86_64-linux.fetchurl;
        }
      );

      # ariang — AriaNg web UI for aria2, built from source at the commit
      # the in-tree task-name patch targets (upstream master d6a7653). Exposed
      # standalone (untuned legacyPackages, same as dsh) so the npm lock hash
      # can be recomputed via `nix build .#ariang`; consumed by europa via
      # modules/services/aria2.nix's pkgs.callPackage.
      packages.x86_64-linux.ariang = (
        import ./pkgs/ariang {
          lib = nixpkgs.lib;
          fetchFromGitHub = nixpkgs.legacyPackages.x86_64-linux.fetchFromGitHub;
          buildNpmPackage = nixpkgs.legacyPackages.x86_64-linux.buildNpmPackage;
          nodejs = nixpkgs.legacyPackages.x86_64-linux.nodejs;
        }
      );

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

      # nom-web — browser UI for nix's internal-json build logs (see
      # pkgs/nom-web/default.nix). Exposed standalone for the same reason as
      # suno-backup above. Consumed by modules/services/nom-web.nix.
      packages.x86_64-linux.nom-web = (
        import ./pkgs/nom-web {
          lib = nixpkgs.lib;
          buildGoModule = nixpkgs.legacyPackages.x86_64-linux.buildGoModule;
        }
      );

      # arcade-webapp — the jupiterOS Arcade pipeline webapp (DAT currency,
      # aria2 download control, igir verify, Skyscraper metadata, Pegasus
      # launcher-DB generation, curation; Phase 0 stub for now). Built from
      # in-tree stdlib-only source, same pattern as suno-backup/nom-web above
      # — exposed standalone (untuned legacyPackages) so the vendorHash can be
      # recomputed via `nix build .#arcade-webapp` without pulling europa's
      # closure. In-tree per ADR-0002 D2 (no new flake input); will be
      # consumed by modules/services/arcade-webapp.nix (Phase 1) via
      # pkgs.callPackage.
      packages.x86_64-linux.arcade-webapp = (
        import ./pkgs/arcade-webapp {
          lib = nixpkgs.lib;
          buildGoModule = nixpkgs.legacyPackages.x86_64-linux.buildGoModule;
          # W4a version stamping: the exact tree rev goes into the store
          # name AND the binary (-X main.version). Dirty checkouts
          # (self.rev null) report 0.1.0-dev.
          rev = self.rev or "";
        }
      );

      # suno-web — browser UI over the archive suno-backup mirrors: search,
      # metadata filtering, the clip derivation graph, playlists and playback.
      # Unlike suno-backup/nom-web above this is NOT built from in-tree source
      # — it lives in its own repository (github:belikh/suno-web) and arrives
      # as a flake input. Re-exported here so `nix build .#suno-web` still
      # works from this tree, and consumed by europa via sunoWebModule.
      packages.x86_64-linux.suno-web = suno-web.packages.x86_64-linux.suno-web;

      # `nix flake check` builds every registered host closure — for a
      # single-host bootstrap that's cheap, and it's the whole point: prove
      # the thing builds.
      #
      # L2 lane (arcade remediation plan §6.E / W0): the arcade-webapp VM
      # harness (tests/hosts/arcade-webapp-vm.nix) as a testers.runNixOSTest
      # — BUILDING this check boots the VM and runs the in-VM smoke, so
      # `nix build .#checks.x86_64-linux.arcade-webapp-vm` (what CI's
      # arcade-webapp-l2-vm job runs) is a full module/service integration
      # gate. It overrides the mapAttrs toplevel entry of the same name:
      # building the test builds that closure anyway, so the plain toplevel
      # check would be strictly weaker. vmSmokePoweroff=false keeps the VM
      # alive for the driver, which asserts /run/arcade-smoke-verdict —
      # the standalone `make test-arcade-webapp` path (build-vm + serial
      # grep + self-poweroff) is unchanged via the arg's default.
      checks.x86_64-linux =
        (builtins.mapAttrs (_: host: host.config.system.build.toplevel) self.nixosConfigurations)
        // {
          arcade-webapp-vm = untunedPkgs.testers.runNixOSTest {
            name = "arcade-webapp-vm";

            nodes.machine =
              { ... }:
              {
                imports = [ ./tests/hosts/arcade-webapp-vm.nix ];
                jupiter.tests.arcadeWebappVm.poweroffAfterSmoke = false;
                # Match the standalone driver's shape (scripts/
                # test-arcade-webapp.sh boots -m 1024 -smp 2); extra headroom
                # for the real igir verify + generate passes.
                virtualisation.memorySize = 2048;
                virtualisation.cores = 2;
              };

            testScript = ''
              start_all()

              # The smoke service (jupiter-arcade-webapp-smoke) runs the
              # full in-VM sequence — healthz, fixture cards, aria2
              # pause/resume, real-igir verify (amber→green), promote,
              # generate, scrape, curation, eXo, launch-line exec probe —
              # and records PASS/FAIL in /run/arcade-smoke-verdict. It
              # self-poweroffs only in the standalone path; here the VM
              # stays up until this script has read the verdict.
              machine.wait_for_file("/run/arcade-smoke-verdict", timeout=1800)
              verdict = machine.succeed("cat /run/arcade-smoke-verdict").strip()
              if verdict != "PASS":
                  print(machine.succeed("journalctl -u jupiter-arcade-webapp-smoke -n 200 --no-pager || true"))
                  raise Exception(f"arcade-webapp-vm smoke verdict: {verdict}")
            '';
          };

          # L3 lane (arcade remediation plan §6.E / W3): the L2 harness
          # PLUS chromium-in-VM Playwright driving the real dashboard —
          # the only lane whose client sends exactly what a real browser
          # sends (htmx's native HX-Request header, real swaps, real
          # poll timers). Fails on any 4xx on any resource and any
          # duplicate panel id; the only lane that could ever have seen
          # the lifetime 403. Playwright + the chromium browser binary
          # both come from the pinned nixpkgs' in-tree packaging (see
          # tests/hosts/arcade-webapp-browser-vm.nix). CI runs this as
          # the arcade-webapp-l3-browser job; the driver asserts BOTH
          # verdicts — smoke first, then the browser lane.
          arcade-webapp-browser-vm = untunedPkgs.testers.runNixOSTest {
            name = "arcade-webapp-browser-vm";

            nodes.machine =
              { ... }:
              {
                imports = [ ./tests/hosts/arcade-webapp-browser-vm.nix ];
                jupiter.tests.arcadeWebappVm.poweroffAfterSmoke = false;
                # The L2 shape (2048/2) plus chromium headroom — a
                # headless browser on top of the full webapp stack.
                virtualisation.memorySize = 4096;
                virtualisation.cores = 2;
              };

            testScript = ''
              start_all()

              # Smoke first (same contract as the L2 check above), then
              # the browser lane runs strictly after it
              # (After=jupiter-arcade-webapp-smoke.service).
              machine.wait_for_file("/run/arcade-smoke-verdict", timeout=1800)
              verdict = machine.succeed("cat /run/arcade-smoke-verdict").strip()
              if verdict != "PASS":
                  print(machine.succeed("journalctl -u jupiter-arcade-webapp-smoke -n 200 --no-pager || true"))
                  raise Exception(f"arcade-webapp-browser-vm smoke verdict: {verdict}")

              machine.wait_for_file("/run/arcade-browser-verdict", timeout=1800)
              bverdict = machine.succeed("cat /run/arcade-browser-verdict").strip()
              if bverdict != "PASS":
                  print(machine.succeed("journalctl -u jupiter-arcade-webapp-browser -n 200 --no-pager || true"))
                  raise Exception(f"arcade-webapp-browser-vm browser verdict: {bverdict}")
            '';
          };
        };

      # Documentation site: auto-generated from all jupiter.* modules
      # Uses an existing host configuration (amalthea) which already has all
      # modules properly imported and evaluated with correct defaults.
      # Exposed under packages (not a bare `docs` output, which flake check
      # flags as unknown) so `nix build .#docs` keeps working.
      packages.x86_64-linux.docs =
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
          # Pure derivation inputs (no `date`/`git rev-parse` in buildPhase —
          # those made the build impure and uncacheable across checkouts):
          # the commit comes from self.rev ("dirty" when the tree is dirty).
          timestamp = "";
          commit = self.rev or "dirty";
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

                      # Pure: commit comes from self.rev (evaluated, not
                      # shelled out); no timestamp — it made every build
                      # uncached and differed per rebuild of the same tree.
                      commit='${commit}'

                      cat >> src/index.md <<INDEX_EOF2

            ---

            ## Generation Info

            - **Generated from**: \`flake.nix\` \`packages.docs\`
            - **Toolchain**: \`nixosOptionsDoc\` + \`mdBook\`
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

      # pkgs.nixfmt: nixfmt-rfc-style was merged upstream and is now an
      # alias of exactly this package (eval warns on the old name).
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt;

      devShells.x86_64-linux.default =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
        in
        pkgs.mkShell {
          packages = with pkgs; [
            sops
            age
            ssh-to-age
            nixfmt
            # Pinned Go toolchain for the arcade-webapp L1 lane (arcade
            # remediation W0): `make check-arcade-webapp` runs go vet +
            # go test -race (and the fixture gate) with exactly this go,
            # pinned by flake.lock — identical for CI, humans and agents,
            # no registry/channel drift.
            go
          ];
        };
    };
}
