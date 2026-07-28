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
    # Remove legacy /etc/exports.d/zfs.exports to prevent export shadowing.
    # This file is auto-generated from a previous system state and contains
    # /mnt/europa/* exports that conflict with our tank/* exports below.
    statdPort = 662;
  };

  system.activationScripts.cleanupNfsExports = {
    text = ''
      rm -f /etc/exports.d/zfs.exports /etc/exports.d/zfs.exports.lock
    '';
  };

  services.nfs.server.exports = ''
    # Media library for Jellyfin/media hosts (read-only).
    /tank/media        10.1.1.0/24(ro,sync,no_subtree_check)

    # jupiterOS Arcade retro archive (read-only).
    # Each ZFS dataset is exported separately to preserve distinct recordsize configs:
    # - /tank/archive/retro: 1M recordsize (container)
    # - /tank/archive/retro/games: 1M recordsize (curated + 1G1R container)
    # - /tank/archive/retro/games/curated: 1M recordsize (packaged ROM collections)
    # - /tank/archive/retro/games/1g1r: 128K recordsize (DAT metadata only; ROMs fetched from mirrors)
    # - /tank/archive/retro/metadata: 128K recordsize (Pegasus + DAT metadata)
    # - /tank/archive/retro/metadata/pegasus/*: 128K recordsize (Pegasus collections + assets)
    # - /tank/archive/retro/metadata/dats: 128K recordsize (No-Intro, Redump, TOSEC DATs)
    # fsid ensures NFSv4 clients can follow into nested dataset boundaries.
    # no_root_squash allows overlayfs upper layer on kiosks to write as gamer user.
    /tank/archive/retro                           10.1.1.0/24(ro,sync,fsid=10,no_root_squash)
    /tank/archive/retro/games                     10.1.1.0/24(ro,sync,fsid=11,no_root_squash)
    /tank/archive/retro/games/curated             10.1.1.0/24(ro,sync,fsid=12,no_root_squash)
    /tank/archive/retro/games/1g1r                10.1.1.0/24(ro,sync,fsid=13,no_root_squash)
    /tank/archive/retro/metadata                  10.1.1.0/24(ro,sync,fsid=14,no_root_squash)
    /tank/archive/retro/metadata/pegasus          10.1.1.0/24(ro,sync,fsid=15,no_root_squash)
    /tank/archive/retro/metadata/pegasus/collections 10.1.1.0/24(ro,sync,fsid=16,no_root_squash)
    /tank/archive/retro/metadata/pegasus/assets   10.1.1.0/24(ro,sync,fsid=17,no_root_squash)
    /tank/archive/retro/metadata/dats             10.1.1.0/24(ro,sync,fsid=18,no_root_squash)
  '';

  networking.firewall.allowedTCPPorts = [ 2049 ];
}
