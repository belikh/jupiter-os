{ ... }:

# NFS exports — serving the NAS to the rest of the jupiter network.
#
# Scoped to the LAN (10.1.1.0/24) and the headscale mesh (100.64.0.0/10).
# Adjust subnets/datasets to taste. These complement the SMB shares (which are
# better for desktops); NFS is for Linux hosts, jellyfin, and netboot.
{
  services.nfs.server = {
    enable = true;
    # Pin rpc.mountd/statd ports so the firewall rule below is sufficient.
    extraNfsdConfig = "";
  };

  services.nfs.server.exports = ''
    # Media library for a Jellyfin/media host (read-only).
    /tank/media        10.1.1.0/24(ro,sync,no_subtree_check) 100.64.0.0/10(ro,sync,no_subtree_check)

    # Diskless/netboot roots on the SSD (read-only; clients overlay a tmpfs/rw
    # layer). Block-style service data (DB, Loki) goes via iSCSI, not here.
    /srv/netboot       10.1.1.0/24(ro,sync,no_subtree_check)
  '';

  networking.firewall.allowedTCPPorts = [ 2049 ];
}
