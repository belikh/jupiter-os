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
            hostPath
          ];
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

        # HPE MicroServer Gen10 — the ZFS NAS and data hub. Phase 1 untuned
        # bootstrap from cache.nixos.org (stock kernel, no microarch); Phase 2
        # switches to a btver2-tuned closure served from its own Attic cache.
        europa = mkHost ./hosts/europa/configuration.nix; # NAS + data hub

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
