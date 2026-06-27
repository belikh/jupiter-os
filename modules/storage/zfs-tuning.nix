{ lib, ... }:

# Performance tuning for the NAS (HPE MicroServer Gen10: Opteron X3216 APU,
# 2c/1.6GHz, 2×8GB ECC = 16GB dual-channel, 2×1GbE BCM5720, all 4Kn SATA disks).
#
# The serving ceiling is the 1GbE network and ARC capacity, NOT disk speed.
# So this focuses on: right-sizing ARC, keeping the weak CPU out of the way,
# and tuning Samba/NFS + the network stack for throughput.
{
  # ---- ZFS ARC (read cache = serving speed) --------------------------------
  # 16GB box, STORAGE-ONLY (all compute — Loki/Grafana/DB — runs on the diskless
  # elitedesk and persists here via iSCSI/NFS). Reserve ~5GB for OS + the storage
  # daemons (smbd/nfsd/LIO target) + buffers; give ~11GB to ARC.
  boot.extraModprobeConfig = ''
    options zfs zfs_arc_max=11811160064
  '';

  # Don't let the box swap ZFS/ARC out under memory pressure.
  boot.kernel.sysctl = {
    "vm.swappiness" = 10;
    # Bump socket buffers for 1-2GbE throughput.
    "net.core.rmem_max" = 16777216;
    "net.core.wmem_max" = 16777216;
    "net.ipv4.tcp_rmem" = "4096 87380 16777216";
    "net.ipv4.tcp_wmem" = "4096 65536 16777216";
  };

  # ---- Samba throughput (CPU is weak — offload to the kernel) ---------------
  services.samba.settings.global = {
    "use sendfile" = "yes";
    "aio read size" = "1"; # enable async IO for all reads
    "aio write size" = "1";
    "socket options" = "TCP_NODELAY IPTOS_LOWDELAY";
    "min protocol" = "SMB2";
    "read raw" = "yes";
    "write raw" = "yes";
    # Bonded NIC (single logical link) -> multichannel adds nothing; keep off.
    "server multi channel support" = "no";
  };
}
