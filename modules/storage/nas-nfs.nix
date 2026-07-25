{ ... }:

# NFS exports — serving the NAS to the rest of the jupiter network.
#
# Scoped to the LAN (10.1.1.0/24). Headscale/ZeroTier subnets can be added
# later when those networks are established on NixOS.
# These complement the SMB shares (which are better for desktops); NFS is for
# Linux hosts and media servers (e.g. Jellyfin).
{
  services.nfs.server = {
    enable = true;
  };

  services.nfs.server.exports = ''
    # Media library for Jellyfin/media hosts (read-only).
    /tank/media        10.1.1.0/24(ro,sync,no_subtree_check)

    # eXoDOS + eXoWin3x collection (europa/games dataset). Read-only — the
    # europa pool itself is mounted ro, and the TCx Wave kiosks layer a
    # per-kiosk overlayfs on top (modules/desktop/exodos.nix) so game saves
    # land in a persisted upper layer without ever writing back here. Served
    # to the whole LAN so every kiosk sees the same ~1 TB collection
    # (~7,200 DOS + ~1,140 Win3.x titles) without copying.
    /mnt/europa/games  10.1.1.0/24(ro,sync,no_subtree_check,no_root_squash)
  '';

  networking.firewall.allowedTCPPorts = [ 2049 ];
}
