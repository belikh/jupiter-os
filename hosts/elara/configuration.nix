{ ... }:

# SCAFFOLD — home desktop PC (not yet built). Part of the roaming-desktop set:
# identical niri + Syncthing-synced $HOME as the laptop, so io can sit down here
# and it's "home". Registered in flake.nix nixosConfigurations and the CI
# build/boot-test matrices so it gets coverage. Its disk is still a REPLACE-ME
# placeholder — that only produces a build-time warning (see
# modules/storage/zfs-profiles.nix), not a CI failure, until the hardware
# exists. To bring online:
#   1. set jupiter.storage.disk to the real /dev/disk/by-id path
#   2. generate its age key and add it to .sops.yaml
#   3. add a deploy.nodes entry in flake.nix once it's reachable

{
  imports = [
    ../../modules/common-stateful.nix
  ];

  networking.hostName = "elara";
  networking.hostId = "b1176063"; # Randomly generated 8-char hex for ZFS

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
