{ lib, ... }:

# Performance tuning for the NAS (HPE MicroServer Gen10: Opteron X3216 APU,
# 2c/2t 1.6GHz base / 3.0GHz boost, 8GB ECC single-channel, 2×1GbE BCM5720,
# SATA disks).
#
# The serving ceiling is the 1GbE network and ARC capacity, NOT disk speed.
# So this focuses on: right-sizing ARC, keeping the weak CPU out of the way,
# and tuning Samba/NFS + the network stack for throughput.
{
  # ---- ZFS ARC (read cache = serving speed) --------------------------------
  # 3GiB, lowered from 5GiB on 2026-08-13. The old comment's premise —
  # "STORAGE-ONLY (all compute runs on other hosts)" — expired: europa also
  # runs the LIO iSCSI target serving callisto's ROOT, headscale + an embedded
  # DERP relay, Harmonia, the ROM pipeline and suno-backup. ("Attic" in that
  # note is decommissioned.) 5GiB of 7.7GiB left ~2.7GiB for all of it, and the
  # box OOM-killed 5 times, including `iscsi_trx invoked oom-killer` inside
  # transport_generic_new_cmd/target_core_mod — the thread serving callisto's
  # root.
  #
  # Sized from measurement, not a guess. Live arcstats before the change:
  #
  #   overall hit 97%   demand-data hit 97%   demand-metadata hit 99.6%
  #   size 4479MB   data 2055MB   metadata 1362MB   arc_meta_used 2289MB
  #   mru 2597MB    mfu 807MB     memory_throttle_count 0
  #
  # MFU — blocks actually re-referenced — is only 807MB; MRU's 2597MB is mostly
  # single-touch traffic (media streamed over Samba/NFS, sequential NAR reads
  # out of Harmonia, ROM/syncthing scans) that will never be read twice. So
  # most of the 5GiB was not earning its keep.
  #
  # 3GiB and NOT less: arc_meta_used is 2289MB and metadata is the high-value
  # content here (99.6% hit over 1.28B accesses, and every metadata miss is a
  # seek on tank's rust mirror). A 2GiB cap — the first number considered —
  # would sit BELOW current metadata usage and evict exactly what's worth
  # keeping. 3GiB fits metadata plus MFU headroom and returns ~2GiB.
  #
  # Note memory_throttle_count = 0: ZFS never registered memory pressure at
  # all, yet the kernel OOM-killed. ARC's shrinker is asynchronous and did not
  # return memory in time for a GFP_KERNEL allocation in the iSCSI path, so
  # "it's only cache, the kernel will reclaim it" is not load-bearing here.
  # Runtime-writable at /sys/module/zfs/parameters/zfs_arc_max if this needs
  # retuning without a reboot.
  boot.extraModprobeConfig = ''
    options zfs zfs_arc_max=3221225472
  '';

  # ---- Swap: zram, deliberately NOT the rpool/swap zvol --------------------
  # europa had NO active swap at all (`free` showed 0B, and there were zero
  # systemd .swap units) despite a 16G `rpool/swap` zvol existing on disk since
  # 2026-07-24. That zvol is an orphan: zfs-profiles.nix only declares swap
  # under the "impermanent" profile (the kiosks), and europa is "stateful", so
  # nothing ever put it in swapDevices. With no swap and ARC capped at 5GiB of
  # 7.7GiB, the box OOM-killed 5 times — including `iscsi_trx invoked
  # oom-killer` inside transport_generic_new_cmd/target_core_mod, i.e. the
  # iSCSI target thread serving callisto's ROOT filesystem.
  #
  # The orphan zvol is NOT the fix. Swap-on-zvol is a known deadlock path (ZFS
  # needs memory to complete a write while swap waits on ZFS to complete a
  # write), and openzfs/zfs#18200 reports exactly that on Linux 6.17 +
  # OpenZFS 2.3.4 — repeated zvol_tq-0/txg_sync hung >123s. europa runs 6.18.35
  # with ZFS 2.4.3, i.e. newer than both, with no evidence of a fix. The
  # failure mode also inverts the trade badly here: an OOM kills one process,
  # whereas a txg_sync deadlock hangs the whole NAS and takes callisto's root
  # with it. zram is RAM-to-RAM, so ZFS is not in the reclaim path at all.
  # Same mechanism the kiosks already use (services/tcxwave-power-tuning.nix).
  #
  # 25%, not the kiosks' 50%: zram's pages are stored compressed IN RAM, and
  # ARC is still holding up to 5GiB here. Revisit upward once that cap comes
  # down. lz4 for the same reason the kiosks use it — this CPU is weak
  # (2c/2t) and ratio matters less than cycles.
  zramSwap = {
    enable = true;
    algorithm = "lz4";
    memoryPercent = 25;
  };

  boot.kernel.sysctl = {
    # 10 was for a box that would have swapped to DISK ("don't let it swap
    # ZFS/ARC out"). With zram as the only swap device that reasoning inverts:
    # there is no slow device behind it, so throttling swap just forces the
    # kernel to reclaim page cache and ARC instead of compressing the anonymous
    # pages that actually caused the OOMs here (ld at 5.7GB RSS, nix at 6.0GB,
    # Skyscraper at 2.7GB — all anon). 100 is the usual zram-backed setting.
    "vm.swappiness" = 100;
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
    # Single NIC (bonding not yet active) -> multichannel adds nothing; keep off.
    "server multi channel support" = "no";
  };
}
