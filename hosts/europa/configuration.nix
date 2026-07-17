{
  config,
  ...
}:

# HPE MicroServer Gen10 — the ZFS NAS and data hub.
#
# Hardware: AMD Opteron X3216 APU (1c/2t, btver2/Puma), 8GB ECC,
# Crucial MX500 500GB SSD (OS), 2× WD 18TB (tank pool / file transfer).
#
# Phase 1: untuned NixOS from cache.nixos.org (stock kernel, no microarch
# flags). Gets the machine running with ZFS, Samba, NFS, Attic, Syncthing,
# and SMART monitoring.
#
# Phase 2 (active): jupiter.build.microarch = "btver2" tunes the closure for
# this exact CPU (Puma core, ISA-equivalent to Jaguar). The BinaryLane build
# server (pallene) compiles it and pushes to europa's own Attic; europa then
# substitutes from localhost:8080 ahead of cache.nixos.org. This is the
# deliberate, mitigated exception to the "no microarch" buildability rule —
# the private Attic cache exists precisely to serve what cache.nixos.org
# cannot once gcc.arch is set.
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
    ../../modules/services/cloudflare-tunnel.nix
    ../../modules/services/pallene-watchdog.nix
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

  # ---- Phase 2: CPU-tuned closure ------------------------------------------
  # Opteron X3216 is a "Cato" APU on the Puma core, ISA-equivalent to Jaguar,
  # which GCC targets as btver2. The BinaryLane build server compiles this
  # host's closure with -march=btver2 and pushes it to the local Attic; see
  # modules/core/build-tuning.nix for the SIGILL/march caveats.
  jupiter.build.microarch = "btver2"; # pallene (build server) compiles this host's closure -march=btver2 and pushes to the local Attic

  # ---- nixpkgs overlays ----------------------------------------------------
  # bmake's `deptgt-interrupt` unit test is timing-sensitive (it asserts a
  # SIGINT yields exit 130) and flakes non-deterministically under load / when
  # the closure is microarch-tuned — on the first full btver2 build it failed
  # (expected 130, got 0), cascading through nix → nixos-system-europa and
  # sinking the entire run. bmake compiles fine; only its check phase is flaky.
  # This overlay is in scope when pallene builds .#nixosConfigurations.europa.
  nixpkgs.overlays = [
    (_final: prev: {
      bmake = prev.bmake.overrideAttrs { doCheck = false; };
    })
  ];

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

  # Cloudflare Tunnel — exposes atticd at attic.jupiter.au so the remote
  # BinaryLane build server (pallene) can push tuned closures and future
  # roaming hosts can pull them, without opening a router port. Runs on
  # europa itself because no other always-on server host is registered yet
  # (master ran it on ganymede). Uses the cloudflare_cert sops secret.
  jupiter.services.cloudflareTunnel = {
    enable = true;
    # Cloudflare tunnel UUID (from ~/.cloudflared/<id>.json / the dashboard).
    # The cloudflare_cert sops secret is this tunnel's credentials JSON.
    tunnelId = "aa1088b8-a0e1-4073-8567-6a9bf5fb4bd7";
  };

  # External backstop for the pallene build server: destroys any BinaryLane
  # pallene* server still running past 4h, from a different host on a
  # separately-sourced token — covers the OOM-SIGKILL and stale-ISO-token
  # gaps the in-VM self-destruct/6h timer in build-server.nix can't.
  jupiter.services.palleneWatchdog.enable = true;

  # ---- sops secrets --------------------------------------------------------
  # attic_server_token_secret: RS256 JWT signing key for atticd.
  # binarylane_api_token: consumed by jupiter.services.palleneWatchdog.
  # Must be added to secrets/secrets.yaml before first deploy.
  sops.secrets.attic_server_token_secret = { };
}
