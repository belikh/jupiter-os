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

    # Persistent state for the diskless netboot build host (callisto at
    # 10.1.1.3, see hosts/callisto/configuration.nix). Read-write + no_root_squash:
    # callisto's root needs to write its SSH host keys, sops state, logs, etc.
    # The dataset is created by modules/storage/zfs-nas.nix. Scoped to
    # callisto's reserved IP only — no other host should be writing here.
    /tank/services/callisto  10.1.1.3(rw,sync,no_subtree_check,no_root_squash)
  '';

  networking.firewall.allowedTCPPorts = [ 2049 ];
}
