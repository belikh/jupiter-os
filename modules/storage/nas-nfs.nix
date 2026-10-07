{ config, ... }:

# NFS exports — serving the NAS to the rest of the jupiter network.
#
# Scoped to the LAN (jupiter.fleet.lanCidr). Headscale/ZeroTier subnets can
# be added later when those networks are established on NixOS.
# These complement the SMB shares (which are better for desktops); NFS is for
# Linux hosts and media servers (e.g. Jellyfin).
{
  # The export lines reference jupiter.fleet.* (topology single source).
  imports = [ ../network/fleet.nix ];

  services.nfs.server = {
    enable = true;
  };

  services.nfs.server.exports = ''
    # Media library for Jellyfin/media hosts (read-only).
    /tank/media        ${config.jupiter.fleet.lanCidr}(ro,sync,no_subtree_check)

    # jupiterOS Arcade retro archive (read-only).
    # Curated collections (eXoDOS, eXoWin3x, C64 Dreams, OneLoad64, etc.) +
    # 1G1R DAT metadata (No-Intro, Redump, TOSEC) + generated Pegasus metadata.
    # Served to 10.1.1.0/24 so all TCxWave kiosks can mount it.
    # no_root_squash allows overlayfs upper layer on kiosks to write as gamer user.
    # crossmnt allows NFSv4 clients to traverse into child ZFS datasets
    # no_subtree_check suppresses spurious ESTALE errors on crossing
    /tank/archive/retro  ${config.jupiter.fleet.lanCidr}(ro,sync,no_subtree_check,crossmnt,no_root_squash)

    # callisto bulk data. callisto has no local disk — its root is a 275G
    # zvol on rpool (europa's SSD mirror) carried over iSCSI, and it fills
    # up. Growing service data (HAOS guest images, etc.) goes here on the
    # big tank pool instead. Read-write and scoped to callisto alone;
    # no_root_squash so root-owned services on callisto can write (same
    # rationale as the retro export).
    #
    # `async`, NOT `sync` (changed 2026-10, explicitly requested): this
    # dataset lives on tank (the spinning-rust mirror), and a `sync` export
    # forces a ZFS fsync per small-file WRITE — which is exactly what made
    # many-small-file writes crawl. `async` lets nfsd reply before the data
    # is committed, so those writes batch into the normal ZIL/txg flush.
    # ACCEPTED TRADE: a europa power loss / panic can lose or tear recent
    # writes to this export. It is callisto-scoped and holds regenerable-ish
    # service data; do NOT extend `async` to the exports above without the
    # same call, and back out if this ever holds the only copy of anything.
    /tank/services/callisto  ${config.jupiter.fleet.addresses.callisto}/32(rw,async,no_subtree_check,no_root_squash)

    # ci-distributed.yml's raw --log-format internal-json build logs
    # (root:root 0644, world-readable — no squash tricks needed). callisto
    # is the only consumer (jupiter-nom-web, modules/services/nom-web.nix),
    # so unlike the exports above this is scoped to that one host rather
    # than the whole LAN — these logs carry raw builder output. Confirmed
    # exportfs accepts a plain (non-mountpoint) subdirectory of the /var ZFS
    # dataset fine, no fsid= needed.
    /var/log/jupiter-ci  ${config.jupiter.fleet.addresses.callisto}/32(ro,sync,no_subtree_check)
  '';

  networking.firewall.allowedTCPPorts = [ 2049 ];
}
