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
    # Curated collections (eXoDOS, eXoWin3x, C64 Dreams, OneLoad64, etc.) +
    # 1G1R DAT metadata (No-Intro, Redump, TOSEC) + generated Pegasus metadata.
    # Served to 10.1.1.0/24 so all TCxWave kiosks can mount it.
    # no_root_squash allows overlayfs upper layer on kiosks to write as gamer user.
    # crossmnt allows NFSv4 clients to traverse into child ZFS datasets
    # no_subtree_check suppresses spurious ESTALE errors on crossing
    /tank/archive/retro  10.1.1.0/24(ro,sync,no_subtree_check,crossmnt,no_root_squash)
  '';

  networking.firewall.allowedTCPPorts = [ 2049 ];
}
