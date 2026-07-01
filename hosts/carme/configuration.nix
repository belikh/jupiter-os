{ ... }:

# SCAFFOLD — desktop PC at the parents' house (not yet built). Same roaming
# identity as the home desktop, but it lives at the second site and reaches the
# fleet over the headscale mesh, so its Syncthing peers with europa across the
# mesh rather than the LAN. Registered in flake.nix nixosConfigurations and the
# CI build/boot-test matrices, same as hosts/elara/configuration.nix — its
# disk is still REPLACE-ME, which only produces a build-time warning (see
# modules/storage/zfs-profiles.nix), not a CI failure, until the hardware
# exists. Bring-online steps mirror hosts/elara/configuration.nix.
#
# NOTE: offline-tolerant sync matters here — the WAN link can drop, so Syncthing
# (local copy + eventual mirror) is the right tool, not an NFS home.

{
  imports = [
    ../../modules/common-stateful.nix
  ];

  networking.hostName = "carme";
  networking.hostId = "3669cd7d"; # Randomly generated 8-char hex for ZFS

  jupiter = {
    branding.enable = true;
    core.impermanence.enable = true;
    storage = {
      profile = "impermanent";
      disk = "/dev/disk/by-id/REPLACE-ME-carme-os-disk";
    };
    desktop = {
      enable = true;
      compositor = "niri";
    };
    home.enable = true;
    services.syncthing.enable = true;
  };
}
