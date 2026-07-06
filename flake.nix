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
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      impermanence,
      sops-nix,
      ha-linux-agent,
      ...
    }:
    let
      # Inject flake-provided modules via a lexical closure rather than
      # specialArgs, so host files stay plain NixOS modules.
      mkHost =
        hostPath:
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
                ];
              }
            )
            # Provide the robcoterm binary to any host that imports
            # robcoterm-kiosk.nix (all four kiosks do, via tcxwave-kiosk.nix).
            # Lexical closure — no specialArgs (per CLAUDE.md). A future
            # non-kiosk host added to mkHost must also import robcoterm-kiosk.nix
            # or drop this line, else the option won't exist.
            {
              jupiter.robcotermKiosk.package = nixpkgs.lib.mkDefault self.packages.x86_64-linux.robcoterm;
            }
            hostPath
          ];
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
        amalthea = mkHost ./hosts/amalthea/configuration.nix; # jupiter-bedroom
        metis = mkHost ./hosts/metis/configuration.nix; # kitchen
        adrastea = mkHost ./hosts/adrastea/configuration.nix; # office
        thebe = mkHost ./hosts/thebe/configuration.nix; # robbie-room
      };

      # `nix flake check` builds every registered host closure — for a
      # single-host bootstrap that's cheap, and it's the whole point: prove
      # the thing builds.
      checks.x86_64-linux = builtins.mapAttrs (
        _: host: host.config.system.build.toplevel
      ) self.nixosConfigurations;

      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-rfc-style;

      # Native Rust + Slint kiosk binary (robcoterm) — the eventual replacement
      # for the Cage + Chromium stack on the TCx Wave panels. Phase 0 spike:
      # builds and links under stock nixpkgs Rust with NO new flake input.
      # Backend is backend-linuxkms-noseat (DRM/KMS direct, no compositor); the
      # mesa DRI drivers are put on the runtime path via addOpenGLRunpath (the
      # nixpkgs-blessed patchelf alternative — do NOT hand-roll DT_RUNPATH).
      packages.x86_64-linux.robcoterm =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
          # Exclude target/ so a stray local cargo build never lands in the
          # store closure. .gitignore keeps it out of git; this keeps it out
          # of `src = ./apps/robcoterm` regardless of git state.
          src = pkgs.lib.sources.cleanSourceWith {
            src = ./apps/robcoterm;
            filter = name: _type: !(pkgs.lib.hasSuffix "/target" name);
          };
        in
        pkgs.rustPlatform.buildRustPackage {
          pname = "robcoterm";
          version = "0.1.0";
          inherit src;
          cargoLock.lockFile = ./apps/robcoterm/Cargo.lock;

          nativeBuildInputs = [
            pkgs.pkg-config
            pkgs.addDriverRunpath # injects mesa DRI into DT_RUNPATH at fixup
          ];
          buildInputs = [
            pkgs.libdrm
            pkgs.libgbm # linuxkms backend's buffer manager (separate attr; mesa has no .dev here)
            pkgs.libinput
            pkgs.libxkbcommon
            pkgs.udev
            pkgs.mesa
            pkgs.fontconfig
          ];

          # Slint's @image-url() and font refs are resolved by slint-build at
          # compile time, so assets/fonts ship inside src and need no extra
          # install step beyond the default cargo install.
        };

      # Separate dev shell for robcoterm work (cargo + the same sysdeps the
      # derivation builds against). The default ops shell is unchanged.
      devShells.x86_64-linux.robcoterm =
        let
          pkgs = nixpkgs.legacyPackages.x86_64-linux;
        in
        pkgs.mkShell {
          packages =
            with pkgs;
            [
              cargo
              rustc
              rust-analyzer
              rustfmt
              clippy
              pkg-config
              libdrm
              libinput
              libxkbcommon
              udev
              mesa
              fontconfig
            ]
            ++ (pkgs.lib.optional (pkgs ? slint-lsp) slint-lsp);
        };

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
