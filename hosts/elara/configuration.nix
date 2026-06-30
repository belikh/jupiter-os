{ ... }:

# SCAFFOLD — home desktop PC (not yet built). Part of the roaming-desktop set:
# identical niri + Syncthing-synced $HOME as the laptop, so io can sit down here
# and it's "home". Not registered in flake.nix until the hardware exists (its
# REPLACE-ME disk would fail the jupiter.storage assertion). To bring online:
#   1. set jupiter.storage.disk to the real /dev/disk/by-id path
#   2. set a unique networking.hostId (8 hex chars)
#   3. uncomment the `elara` entry in flake.nix nixosConfigurations + add it
#      to the CI build/boot-test matrices
#   4. generate its age key and add it to .sops.yaml

{
  imports = [
    ../../modules/common-stateful.nix
  ];

  networking.hostName = "elara";
  networking.hostId = "REPLACE-ME"; # 8 hex chars, required for ZFS

  jupiter = {
    branding.enable = true;
    # A personal workstation is a fine impermanence candidate: config is
    # declarative (home-manager) and data roams via Syncthing, so nothing
    # irreplaceable lives on the root.
    core.impermanence.enable = true;
    storage = {
      profile = "impermanent";
      disk = "/dev/disk/by-id/REPLACE-ME-elara-os-disk";
    };
    desktop = {
      enable = true;
      compositor = "niri";
    };
    home.enable = true; # same io environment as every other personal machine
    services.syncthing.enable = true; # roams $HOME data dirs via the NAS hub
  };
}
