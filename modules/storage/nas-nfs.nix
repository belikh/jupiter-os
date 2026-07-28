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

    # jupiterOS Arcade retro archive (read-only).
    # NFSv4 cannot reach ZFS child datasets nested >1 level deep via crossmnt alone.
    # Each dataset must be exported separately with unique fsid to allow proper
    # referral following through the dataset hierarchy.
    # no_root_squash allows overlayfs upper layer on kiosks to write as gamer user.
    /tank/archive/retro                           10.1.1.0/24(ro,sync,no_subtree_check,fsid=10,no_root_squash)
    /tank/archive/retro/games                     10.1.1.0/24(ro,sync,no_subtree_check,fsid=11,no_root_squash)
    /tank/archive/retro/games/1g1r                10.1.1.0/24(ro,sync,no_subtree_check,fsid=12,no_root_squash)
    /tank/archive/retro/games/curated             10.1.1.0/24(ro,sync,no_subtree_check,fsid=13,no_root_squash)
    /tank/archive/retro/metadata                  10.1.1.0/24(ro,sync,no_subtree_check,fsid=14,no_root_squash)
    /tank/archive/retro/metadata/pegasus          10.1.1.0/24(ro,sync,no_subtree_check,fsid=15,no_root_squash)
    /tank/archive/retro/metadata/pegasus/collections 10.1.1.0/24(ro,sync,no_subtree_check,fsid=16,no_root_squash)
    /tank/archive/retro/metadata/pegasus/assets   10.1.1.0/24(ro,sync,no_subtree_check,fsid=17,no_root_squash)
  '';

  networking.firewall.allowedTCPPorts = [ 2049 ];
}
