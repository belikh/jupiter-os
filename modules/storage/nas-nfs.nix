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

    # ci-distributed.yml's raw --log-format internal-json build logs
    # (root:root 0644, world-readable — no squash tricks needed). callisto
    # is the only consumer (jupiter-nom-web, modules/services/nom-web.nix),
    # so unlike the exports above this is scoped to that one host rather
    # than the whole LAN — these logs carry raw builder output. Confirmed
    # exportfs accepts a plain (non-mountpoint) subdirectory of the /var ZFS
    # dataset fine, no fsid= needed.
    /var/log/jupiter-ci  10.1.1.3/32(ro,sync,no_subtree_check)
  '';

  networking.firewall.allowedTCPPorts = [ 2049 ];
}
