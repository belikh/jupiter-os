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
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      impermanence,
      sops-nix,
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
                ];
              }
            )
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
