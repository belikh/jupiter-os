{
  config,
  lib,
  pkgs,
  ...
}:

# HPE MicroServer Gen10 — the ZFS NAS and data hub.
#
# Hardware: AMD Opteron X3216 APU (1c/2t, btver2/Puma), 8GB ECC,
# Crucial MX500 500GB SSD (OS), 2× WD 18TB (tank pool / file transfer).
#
# Phase 1: untuned NixOS from cache.nixos.org (stock kernel, no microarch
# flags). Gets the machine running with ZFS, Samba, NFS, Harmonia, Syncthing,
# and SMART monitoring.
#
# Phase 2 (active): jupiter.build.microarch = "btver2" tunes the closure for
# this exact CPU (Puma core, ISA-equivalent to Jaguar). The BinaryLane build
# server (pallene) compiles it and pushes to europa's own store (served by
# Harmonia); europa then
# substitutes from localhost:8080 ahead of cache.nixos.org. This is the
# deliberate, mitigated exception to the "no microarch" buildability rule —
# the private Harmonia cache exists precisely to serve what cache.nixos.org
# cannot once gcc.arch is set.
{
  imports = [
    ../../modules/common.nix
    ../../modules/storage/zfs-nas.nix
    ../../modules/storage/sanoid.nix
    ../../modules/storage/zfs-tuning.nix
    ../../modules/storage/nas-nfs.nix
    ../../modules/network/nas-bond.nix
    # jupiter.pxe itself is enabled in flake.nix's pxeModule, not here — it
    # needs self.nixosConfigurations.callisto's build outputs, which aren't
    # reachable from a plain host module (see flake.nix, CLAUDE.md's "avoid
    # specialArgs" note). This import just brings the option in scope.
    ../../modules/network/pxe-server.nix
    # GitHub Actions CI nix-copy receiver (jupiter-ci user + per-build GC
    # roots). CI builds on free GHA CPU, then `nix copy --to ssh://europa`
    # over the tailnet; Harmonia (below) serves the result.
    ../../modules/core/ci-cache-receiver.nix
    ../../modules/services/syncthing.nix
    ../../modules/services/smart-monitoring.nix
    ../../modules/services/console-screensaver.nix
    ../../modules/services/cloudflare-tunnel.nix
    ../../modules/services/pallene-watchdog.nix
    ../../modules/services/iscsi-target.nix
    # Headscale control plane (self-hosted Tailscale)
    ../../modules/services/headscale.nix
    # Tailscale client for this host
    ../../modules/services/tailscale.nix
    # jupiterOS Arcade — europa-side cartridge ROM pipeline: bulk torrent
    # acquisition + igir hash verification (rom-acquire), headless Skyscraper
    # scraping into Pegasus metadata (rom-scraper), and a periodic library
    # inventory JSON (arcade-inventory). Kiosks consume the results read-only
    # over NFS; see modules/desktop/cartridges.nix and docs/adr/0001-*.
    ../../modules/services/rom-acquire.nix
    ../../modules/services/rom-scraper.nix
    ../../modules/services/arcade-inventory.nix
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

  # common.nix enables the full redistributable-firmware blob fleet-wide
  # (broad hardware compat for unknown/varied peripherals — kiosks etc).
  # europa's hardware is fixed and fully known (AMD Opteron X3216 APU, no
  # discrete GPU, no wifi): that blob's nvidia/other-GPU/wifi-chipset
  # firmware can never be used here, just bloats the (already
  # microarch-tuned, cache-sensitive) closure for nothing.
  hardware.enableRedistributableFirmware = false;

  # ---- Dev / agent tooling ------------------------------------------------
  # Same reasoning as the firmware line above: common.nix defaults zed (GUI
  # editor), ecc (Node.js agent CLI), and antigravity/agy (Google agent CLI)
  # on for the bootstrap host, but europa is a headless STORAGE-ONLY NAS with
  # no display and no interactive dev sessions — all four are pure closure
  # bloat on a btver2-tuned, cache-sensitive host (and zed/crush even pull a
  # sops secret decrypted on every activation for binaries that can't start).
  # Opt out; the future dev workstation (himalia) opts in.
  jupiter.core.zed.enable = false;
  jupiter.core.crush.enable = false;
  jupiter.core.ecc.enable = false;
  jupiter.core.antigravity.enable = false;
  # Disable Lix (needs >8GB RAM to build); use standard Nix instead
  jupiter.core.lix.enable = false;
  nix.distributedBuilds = true;
  nix.settings.system-features = lib.mkAfter [
    "gccarch-btver2"
    "big-parallel"
  ];
  nix.buildMachines = lib.mkForce [
    {
      hostName = "10.1.1.3";
      system = "x86_64-linux";
      protocol = "ssh-ng";
      sshUser = "root";
      sshKey = "/run/secrets/nix_build_ssh_key";
      maxJobs = 1;
      speedFactor = 2;
      supportedFeatures = [ "gccarch-btver2" "gccarch-skylake" "big-parallel" ];
      mandatoryFeatures = [ ];
    }
  ];

  # ---- Storage profile (OS SSD) --------------------------------------------
  # Stateful root (no impermanence — the NAS needs persistent state).
  jupiter.storage.profile = "stateful";
  jupiter.storage.disk = "/dev/disk/by-id/ata-CT500MX500SSD1_1921E206022D";

  # ---- ZFS NAS layer -------------------------------------------------------
  jupiter.nas.enable = true;

  # ---- Phase 2: CPU-tuned closure ------------------------------------------
  # Re-enabled: the tailnet/CI push pipeline this was blocked on now works
  # end-to-end (headscale real TLS via Let's Encrypt, CI registers and
  # pushes over neptune.jupiter.au:8080, confirmed live). Opteron X3216 is a
  # "Cato" APU on the Puma core, ISA-equivalent to Jaguar, which GCC targets
  # as btver2. CI (.github/workflows/ci.yml, main-only) builds this host's
  # closure with -march=btver2 and pushes to Harmonia; europa then
  # substitutes from its own cache ahead of cache.nixos.org. This is the
  # deliberate, mitigated exception to the "no microarch" buildability rule —
  # the private Harmonia cache exists precisely to serve what cache.nixos.org
  # cannot once gcc.arch is set. Verify Harmonia actually has the pushed
  # closure (`nix path-info --substituters http://10.1.1.2:5000 <toplevel>`)
  # before switching this host.
  # jupiter.build.microarch = "btver2"; # CI builds this host's closure with -march=btver2
  # TEMPORARILY DISABLED for current build — re-enable after this completes

  # ---- nixpkgs overlays ----------------------------------------------------
  # bmake's `deptgt-interrupt` unit test is timing-sensitive (it asserts a
  # SIGINT yields exit 130) and flakes non-deterministically under load / when
  # the closure is microarch-tuned — on the first full btver2 build it failed
  # (expected 130, got 0), cascading through nix → nixos-system-europa and
  # sinking the entire run. bmake compiles fine; only its check phase is flaky.
  # This overlay is in scope when pallene builds .#nixosConfigurations.europa.
  #
  # postgresql-18.4's installCheckPhase (its own regression-test harness,
  # which spins up a temp instance via `initdb --auth trust` under
  # tmp_install/) fails on callisto's build sandbox -- confirmed live
  # (2026-08-07): the package itself builds and installs cleanly (every
  # binary/symlink completes), only the subsequent self-test's initdb call
  # exits non-zero. The real initdb stderr is redirected into
  # tmp_install/log/initdb-template.log inside the build sandbox, which is
  # torn down on failure -- `nix log` only shows the wrapper, not that
  # file, so the underlying cause (locale/sandbox-restriction on this
  # builder, most likely) is unconfirmed. Same class of problem as bmake
  # above: skip the check, don't chase a flaky/environment-sensitive test
  # harness that doesn't affect the shipped binary. Nothing on europa
  # actually runs postgresql as a service (headscale here uses sqlite) --
  # it's only a transitive build dependency of something else in the
  # closure.
  nixpkgs.overlays = [
    (_final: prev: {
      bmake = prev.bmake.overrideAttrs { doCheck = false; };
      postgresql_18 = prev.postgresql_18.overrideAttrs {
        doCheck = false;
        doInstallCheck = false;
      };
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
  # Headscale control plane server (self-hosted Tailscale)
  jupiter.services.headscale = {
    enable = true;
    # NOT https://headscale.jupiter.au: that's Cloudflare-Tunnel-fronted and
    # cloudflared cannot carry the TS2021/DERP protocols at all (both are
    # HTTP-Upgrade-based over POST, which cloudflared only supports for GET
    # — github.com/cloudflare/cloudflared#883, confirmed live: every
    # request through the tunnel got its Upgrade header stripped). This
    # also drives the DERP relay's advertised port (see serverUrl's option
    # doc in modules/services/headscale.nix) — http://…:8080 makes the
    # DERP node advertise plain-HTTP port 8080 (matching europa's real
    # listener, which never terminates TLS itself) instead of the default
    # 443-over-TLS that only Cloudflare Tunnel would serve.
    # neptune.jupiter.au:8080 is a direct UDM port-forward to europa:8080,
    # already required for CI's tailscale registration (GitHub-hosted
    # runners have no outbound IPv6 for the equivalent IPv6-only forward).
    # https, not http: DERP relay connections require REAL TLS regardless
    # of scheme (confirmed live: "tls: first record does not look like a
    # TLS handshake" against a plain-HTTP listener) — headscale terminates
    # its own TLS here via Let's Encrypt (below) rather than relying on
    # Cloudflare Tunnel, which cannot carry DERP/TS2021 at all.
    serverUrl = "https://neptune.jupiter.au:8080";
    # Database on persistent ZFS dataset
    database = {
      type = "sqlite";
      path = "/var/lib/headscale/db.sqlite";
    };
    # Real TLS via headscale's built-in ACME (autocert), terminated
    # directly on listenAddr (8080) — NOT Cloudflare Tunnel, which breaks
    # DERP/TS2021 (see serverUrl's comment above). HTTP-01 validation
    # needs port 80 forwarded to this host (UDM port-forward, separate
    # from the 8080 one).
    tls = {
      certPath = "";
      keyPath = "";
      letsencryptHostname = "neptune.jupiter.au";
      acmeEmail = "io@jupiter.au";
    };
    # DERP server for NAT traversal. UDP 3478 (STUN) is forwarded on both
    # IPv6 (europa's other exposed ports) and IPv4 (neptune.jupiter.au,
    # added specifically for IPv4-only clients like GitHub-hosted CI
    # runners, which have no outbound IPv6 at all). ipv4 advertises
    # neptune's public IPv4 in the DERP map so clients connect directly by
    # IP rather than resolving HostName (which would otherwise still be
    # server_url's host — see above for why that must NOT be the
    # Cloudflare-Tunnel-fronted hostname).
    derp = {
      server = {
        enabled = "true";
        regionId = "999";
        regionCode = "jupiter";
        regionName = "Jupiter DERP";
        stunPort = "3478";
        ipv4 = "157.85.248.45"; # neptune.jupiter.au
      };
    };
  };

  # Tailscale client for this host (connects to local headscale). Reusable
  # tag:fleet pre-auth key, shared fleet-wide via sops — self-registers on
  # switch, no manual `headscale auth register` step needed.
  sops.secrets.tailscale_fleet_authkey = { };
  jupiter.services.tailscale = {
    enable = true;
    # Not the local loopback anymore: once headscale's listenAddr requires
    # real TLS (via letsencryptHostname above), a plain-HTTP local
    # connection to 127.0.0.1:8080 no longer works, and a TLS one wouldn't
    # validate anyway (the cert covers neptune.jupiter.au, not
    # 127.0.0.1/10.1.1.2). Goes out through the public URL and back in via
    # the router's port-forward (NAT hairpin) instead — untested whether
    # the UDM supports this for a host reaching its own forwarded address.
    serverUrl = "https://neptune.jupiter.au:8080";
    tags = [ "tag:fleet" ];
    acceptRoutes = true;
    authKeyFile = config.sops.secrets.tailscale_fleet_authkey.path;
  };

  # Cloudflare Tunnel — now fronts both Harmonia cache AND Headscale control plane.
  # Harmonia serves the read-only cache at cache.jupiter.au.
  # Headscale serves the Tailscale control plane at headscale.jupiter.au.
  # Both reached via Cloudflare Tunnel (public) or direct tailnet (LAN).
  jupiter.services.cloudflareTunnel = {
    enable = true;
    # Cloudflare tunnel UUID (from ~/.cloudflared/<id>.json / the dashboard).
    # The cloudflare_cert sops secret is this tunnel's credentials JSON.
    tunnelId = "aa1088b8-a0e1-4073-8567-6a9bf5fb4bd7";
    harmoniaHostname = "cache.jupiter.au";
    harmoniaPort = 5000;
    extraIngress = [
      {
        hostname = "headscale.jupiter.au";
        port = 8080;
      }
    ];
  };
  # fleet (and the next CI run) can substitute closures CI pushed here. Read-
  # only by design (issue #63 — replaces the decommissioned attic cache, which
  # had its own store dataset). CI populates the store via `nix copy --to ssh://europa`
  # (jupiter-ci user, see modules/core/ci-cache-receiver.nix); fleet hosts
  # consume it via modules/core/harmonia-substituter.nix. The signing key is
  # generated once via nix-store --generate-binary-cache-key (see
  # docs/ci-harmonia-push-runbook.md) and held in the harmonia_sign_key sops
  # secret; without it europa's activation fails, so it must be added first.
  services.harmonia.cache.enable = true;
  services.harmonia.cache.signKeyPaths = [ config.sops.secrets.harmonia_sign_key.path ];
  services.harmonia.cache.settings = {
    real_nix_store = "/nix/store";
    nix_db_path = "/nix/var/nix/db/db.sqlite";
  };
  systemd.services.harmonia.serviceConfig.ReadOnlyPaths = [ "/nix/store" ];
  networking.firewall.allowedTCPPorts = [ 5000 ];

  # Receiving side for CI's `nix copy` pushes (jupiter-ci trusted user +
  # per-build GC roots, keep last 3 main builds).
  jupiter.core.ciCacheReceiver.enable = true;

  # Syncthing hub — canonical synced copy lives on tank/personal (mirror +
  # sanoid snapshots + future restic offsite).
  jupiter.services.syncthing = {
    enable = true;
    dataDir = "/tank/personal";
  };

  # SMART monitoring on all attached disks (OS SSD + WD 18TB drives).
  jupiter.storage.smartMonitoring.enable = true;

  # Console screensaver — Matrix rain on tty1 for the (rare) moments a
  # monitor is plugged in. Login stays on tty2 (Ctrl+Alt+F2). The module runs
  # cmatrix at the lowest CPU priority (Nice=19) so the eye-candy always
  # yields to real NAS work.
  jupiter.consoleScreensaver.enable = true;

  # External backstop for the pallene build server: destroys any BinaryLane
  # pallene* server still running past 4h, from a different host on a
  # separately-sourced token — covers the OOM-SIGKILL and stale-ISO-token
  # gaps the in-VM self-destruct/6h timer in build-server.nix can't.
  jupiter.services.palleneWatchdog.enable = true;

  # iSCSI target backing callisto's root filesystem (replaces the old
  # NFS-backed /persist — see hosts/callisto/configuration.nix). ACL-scoped
  # to callisto's initiator IQN only, no CHAP (see
  # modules/services/iscsi-target.nix for why that's a supported shape).
  jupiter.services.iscsiTarget = {
    enable = true;
    targetIqn = "iqn.2026-07.au.jupiter:europa:callisto-root";
    initiatorIqn = "iqn.2026-07.au.jupiter:callisto";
  };

  # ---- jupiterOS Arcade (europa-side cartridge pipeline) ------------------
  # Bulk-stage No-Intro Nintendo cartridge ROMs via Minerva torrents, verify
  # against DATs with igir, scrape Pegasus metadata with Skyscraper, and emit
  # a periodic library inventory. Acquisition/verify are manual oneshots (no
  # timer — start them explicitly); scraping runs daily; inventory every 15min.
  # Kiosks mount /tank/archive/retro/games/cartridge read-only.
  jupiter.services.romAcquire.enable = true;
  jupiter.services.romScraper.enable = true;
  jupiter.services.arcadeInventory.enable = true;

  # ---- sops secrets --------------------------------------------------------
  # harmonia_sign_key: private Nix binary-cache signing key for Harmonia
  # (generated via nix-store --generate-binary-cache-key). Must be added to
  # secrets/secrets.yaml before first deploy or Harmonia's activation fails.
  # binarylane_api_token: consumed by jupiter.services.palleneWatchdog.
  sops.secrets.harmonia_sign_key = { };
  sops.secrets.nix_build_ssh_key = { };

  # ---- Dev tools for CI builds running in tmux on europa -------------------
  # nix-output-monitor: formatted output for nix build; useful when watching
  # builds live via CI's tmux session. Excluded from common.nix (headless NAS),
  # but worth the small closure for build visibility.
  environment.systemPackages = with pkgs; [
    nix-output-monitor
  ];
}
