{
  config,
  ...
}:

# HPE MicroServer Gen10 — the ZFS NAS and data hub.
#
# Hardware: AMD Opteron X3216 APU (1c/2t, btver2/Puma), 8GB ECC,
# Crucial MX500 500GB SSD (OS), 2× WD 18TB (tank pool / file transfer).
#
# Phase 1 (this config): untuned NixOS from cache.nixos.org. Stock kernel,
# no microarch flags. Gets the machine running with ZFS, Samba, NFS, Attic,
# Syncthing, and SMART monitoring.
#
# Phase 2 (deferred): once Attic is live, the BinaryLane build server
# compiles a btver2-tuned closure and pushes it here, then europa switches
# to it via nixos-rebuild.
{
  imports = [
    ../../modules/common.nix
    ../../modules/storage/zfs-nas.nix
    ../../modules/storage/sanoid.nix
    ../../modules/storage/zfs-tuning.nix
    ../../modules/storage/nas-nfs.nix
    ../../modules/network/nas-bond.nix
    ../../modules/services/attic-server.nix
    ../../modules/services/syncthing.nix
    ../../modules/services/smart-monitoring.nix
    ../../modules/services/console-screensaver.nix
  ];

  networking.hostName = "europa";
  networking.hostId = "deadbeef"; # Stable per-host 8-char hex, required for ZFS

  # ---- Platform / kernel ---------------------------------------------------
  # The HPE MicroServer Gen10 wires its 4 data-drive bays to a Marvell 88SE9230
  # PCIe SATA HBA; only the single OS port is on the AMD FCH (which is why the
  # OS SSD always enumerates regardless). The 88SE9230 has a PCIe DMA bug: with
  # AMD IOMMU enabled its DMA strikes IOMMU-reserved memory, every AHCI
  # IDENTIFY times out, and the data drives never appear — so `tank` can't
  # import. Disabling AMD IOMMU is the proven, community-documented fix for
  # this exact machine (HPE even ships it with IOMMU off by default). This is a
  # boot *parameter* on the stock linuxPackages kernel, NOT a custom kernel —
  # rule-compliant for a ZFS host. europa runs no VMs, so IOMMU isn't needed.
  boot.kernelParams = [ "amd_iommu=off" ];

  # ---- Storage profile (OS SSD) --------------------------------------------
  # Stateful root (no impermanence — the NAS needs persistent state).
  jupiter.storage.profile = "stateful";
  jupiter.storage.disk = "/dev/disk/by-id/ata-CT500MX500SSD1_1921E206022D";

  # ---- ZFS NAS layer -------------------------------------------------------
  jupiter.nas.enable = true;

  # ---- Networking ----------------------------------------------------------
  # Static identity below the DHCP pool so iSCSI/NFS clients have a stable
  # target. Uses enp2s0f1 (the live NIC — enp2s0f0 has no link on this unit).
  networking.useDHCP = false;
  networking.interfaces.enp2s0f1.ipv4.addresses = [
    {
      address = "10.1.1.2";
      prefixLength = 24;
    }
  ];
  networking.defaultGateway = "10.1.1.1";

  # Static networking leaves no nameservers behind — common.nix defers DNS to
  # DHCP, which europa disabled above, so without this /etc/resolv.conf ends
  # up empty and the box can't resolve cache.nixos.org or any substituter.
  # The UniFi gateway resolves; 1.1.1.1 is the fallback if it's ever down.
  networking.nameservers = [
    "10.1.1.1"
    "1.1.1.1"
  ];

  # LACP bonding — disabled until the UniFi switch-side is configured.
  jupiter.nas.bond.enable = false;

  # ---- Services ------------------------------------------------------------
  # Binary cache for the BinaryLane "rebuild the world" build server.
  # Storage on tank/services/attic (created by the zfs-nas dataset service).
  jupiter.services.attic.enable = true;

  # Syncthing hub — canonical synced copy lives on tank/personal (mirror +
  # sanoid snapshots + future restic offsite).
  jupiter.services.syncthing = {
    enable = true;
    dataDir = "/tank/personal";
  };

  # SMART monitoring on all attached disks (OS SSD + WD 18TB drives).
  jupiter.storage.smartMonitoring.enable = true;

  # Console screensaver — Matrix rain on tty1 for the (rare) moments a
  # monitor is plugged in. Login stays on tty2 (Ctrl+Alt+F2).
  jupiter.consoleScreensaver.enable = true;

  # ---- sops secrets --------------------------------------------------------
  # attic_server_token_secret: RS256 JWT signing key for atticd.
  # Must be added to secrets/secrets.yaml before first deploy.
  sops.secrets.attic_server_token_secret = { };
}
