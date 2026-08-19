{
  config,
  lib,
  pkgs,
  ...
}:

# HPE MicroServer Gen10 — the ZFS NAS and data hub.
#
# Hardware: AMD Opteron X3216 APU (2c/2t — one Excavator module, 2 integer
# cores, no SMT; family 21 model 96, so bdver4), 8GB ECC,
# Crucial MX500 500GB SSD (OS), 2× WD 18TB (tank pool / file transfer).
#
# Phase 1: untuned NixOS from cache.nixos.org (stock kernel, no microarch
# flags). Gets the machine running with ZFS, Samba, NFS, Harmonia, Syncthing,
# and SMART monitoring.
#
# Phase 2 (inactive since 2026-08-16): jupiter.build.microarch = "bdver4"
# tunes the closure for this exact CPU — but no CI pipeline is delivering a
# tuned closure (last push f58fc16/2026-08-06 was untuned), and untuned
# europa substitutes its whole closure from cache.nixos.org + its own
# Harmonia. See the note at the microarch setting below before re-enabling.
{
  imports = [
    ../../modules/common.nix
    ../../modules/storage/zfs-nas.nix
    ../../modules/storage/sanoid.nix
    ../../modules/storage/zfs-tuning.nix
    ../../modules/storage/nas-nfs.nix
    ../../modules/network/nas-bond.nix
    ../../modules/network/pxe-server.nix
    ../../modules/core/ci-cache-receiver.nix
    ../../modules/services/syncthing.nix
    ../../modules/services/smart-monitoring.nix
    ../../modules/services/console-screensaver.nix
    ../../modules/services/cloudflare-tunnel.nix
    ../../modules/services/iscsi-target.nix
    ../../modules/services/headscale.nix
    ../../modules/services/tailscale.nix
    ../../modules/services/rom-acquire.nix
    ../../modules/services/rom-scraper.nix
    ../../modules/services/arcade-inventory.nix
    ../../modules/services/suno-backup.nix
    ../../modules/services/suno-web.nix
    ../../modules/services/aria2.nix
    ../../modules/core/build-machines.nix
  ];

  networking.hostName = "europa";
  # FIXME(maintenance-window): borrowed placeholder hostId on a LIVE ZFS host.
  # Mint a real random 8-hex hostId and apply it together with `zpool
  # reguid`/export-import at a planned maintenance window — changing it
  # remotely in git alone risks breaking tank import on the next deploy
  # (forceImportRoot=false here), so this is deliberately left as-is until
  # the operator can sit at the console.
  networking.hostId = "deadbeef"; # Stable per-host 8-char hex, required for ZFS

  # ---- Platform / kernel ---------------------------------------------------
  # The HPE MicroServer Gen10 wires its 4 data-drive bays to a Marvell 88SE9230
  # PCIe SATA HBA; only the single OS port is on the AMD FCH (which is why the
  # OS SSD always enumerates regardless). The 88SE9230 has a PCIe DMA bug: with
  # AMD IOMMU enabled its DMA strikes IOMMU-reserved memory, every AHCI
  # IDENTIFY times out, and the data drives never appear — so `tank` can't
  # import. Disabling AMD IOMMU is the proven, community-documented fix for
  # this exact machine (HPE even ships it with IOMMU off by default). This is a
  # boot *parameter* on the stock linuxPackages kernel
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
  # bloat on a bdver4-tuned, cache-sensitive host (and zed/crush even pull a
  # sops secret decrypted on every activation for binaries that can't start).
  # Opt out; the future dev workstation (himalia) opts in.
  jupiter.core.zed.enable = false;
  jupiter.core.crush.enable = false;
  jupiter.core.ecc.enable = false;
  jupiter.core.antigravity.enable = false;
  # Disable Lix (needs >8GB RAM to build); use standard Nix instead
  jupiter.core.lix.enable = false;
  nix.settings.system-features = lib.mkAfter [
    "gccarch-bdver4"
    "big-parallel"
  ];
  # Retain build-time outputs alongside the rooted runtime closures.
  # keep-derivations is already true, so a pinned toplevel reaches its full
  # derivation graph; keep-outputs materializes those derivations' outputs
  # (the tuned toolchain — binutils, rustc, clang, llvm, ninja, dev libs) so
  # Harmonia can serve the build closure to CI's remote builders instead of
  # them rebuilding it from source each run. Cost: europa's store grows to
  # the full build closure of the retained builds.
  nix.settings.keep-outputs = true;

  # ---- Remote builder: callisto --------------------------------------------
  # Delegate eligible builds to callisto (fleet address in
  # modules/network/fleet.nix): 6c/6t i5-8500T vs this 2c/2t Opteron —
  # several times faster per core. Formerly inlined here; now the shared
  # modules/core/build-machines.nix with its two europa-specific deviations
  # as explicit flags — behavior identical to the old inline slice:
  #   * includeKiosks=false — europa delegates to callisto ALONE (the module
  #     defaults to also wiring the 4 kiosks).
  #   * advertiseBdver4=false — supportedFeatures deliberately OMITS
  #     gccarch-bdver4: callisto is Coffee Lake/Skylake with no XOP/TBM/FMA4
  #     (Excavator-only extensions bdver4 code may emit). Advertising it
  #     (pre-08fd609) made perl's miniperl bootstrap SIGILL while "building
  #     on europa" — actually mis-executing on callisto. Delegation is safe
  #     again NOW precisely because europa is untuned: its derivations carry
  #     no gccarch-* tag. If microarch is ever re-enabled, revisit this
  #     matrix first (build bdver4 locally or on CI only).
  # Europa (bdver4/Excavator) uses all Skylake hosts (callisto + 4 kiosks) as builders.
  # Not part of the symmetric pool (different microarch).
  nix.distributedBuilds = true;
  nix.buildMachines = [
    {
      hostName = config.jupiter.fleet.addresses.callisto;
      system = "x86_64-linux";
      protocol = "ssh-ng";
      sshUser = "root";
      sshKey = config.sops.secrets.nix_build_ssh_key.path;
      maxJobs = 1;

      speedFactor = 2;
      supportedFeatures = [
        "gccarch-skylake"
        "gccarch-bdver4"
        "big-parallel"
      ];
      mandatoryFeatures = [ ];
    }
    {
      hostName = "amalthea.localdomain";
      system = "x86_64-linux";
      protocol = "ssh-ng";
      sshUser = "root";
      sshKey = config.sops.secrets.nix_build_ssh_key.path;
      maxJobs = 1;

      speedFactor = 1;
      supportedFeatures = [
        "gccarch-skylake"
        "gccarch-bdver4"
        "big-parallel"
      ];
      mandatoryFeatures = [ ];
    }
    {
      hostName = "metis.localdomain";
      system = "x86_64-linux";
      protocol = "ssh-ng";
      sshUser = "root";
      sshKey = config.sops.secrets.nix_build_ssh_key.path;
      maxJobs = 1;

      speedFactor = 1;
      supportedFeatures = [
        "gccarch-skylake"
        "gccarch-bdver4"
        "big-parallel"
      ];
      mandatoryFeatures = [ ];
    }
    {
      hostName = "adrastea.localdomain";
      system = "x86_64-linux";
      protocol = "ssh-ng";
      sshUser = "root";
      sshKey = config.sops.secrets.nix_build_ssh_key.path;
      maxJobs = 1;

      speedFactor = 1;
      supportedFeatures = [
        "gccarch-skylake"
        "gccarch-bdver4"
        "big-parallel"
      ];
      mandatoryFeatures = [ ];
    }
    {
      hostName = "thebe.localdomain";
      system = "x86_64-linux";
      protocol = "ssh-ng";
      sshUser = "root";
      sshKey = config.sops.secrets.nix_build_ssh_key.path;
      maxJobs = 1;

      speedFactor = 1;
      supportedFeatures = [
        "gccarch-skylake"
        "gccarch-bdver4"
        "big-parallel"
      ];
      mandatoryFeatures = [ ];
    }
  ];

  # SSH config for all builder hosts
  programs.ssh.extraConfig = ''
    Host ${config.jupiter.fleet.addresses.callisto}
      IdentityFile ${config.sops.secrets.nix_build_ssh_key.path}
      IdentitiesOnly yes
    Host amalthea.localdomain
      IdentityFile ${config.sops.secrets.nix_build_ssh_key.path}
      IdentitiesOnly yes
    Host metis.localdomain
      IdentityFile ${config.sops.secrets.nix_build_ssh_key.path}
      IdentitiesOnly yes
    Host adrastea.localdomain
      IdentityFile ${config.sops.secrets.nix_build_ssh_key.path}
      IdentitiesOnly yes
    Host thebe.localdomain
      IdentityFile ${config.sops.secrets.nix_build_ssh_key.path}
      IdentitiesOnly yes
  '';

  # Known host keys for all builders
  programs.ssh.knownHosts = {
    callisto = {
      hostNames = [ config.jupiter.fleet.addresses.callisto ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIINKUMgEPCzZRq74JtvkMmfmT6gOmZWGGq8G9lNqqKsU";
    };
    amalthea = {
      hostNames = [ "amalthea.localdomain" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGQV+BzJbBfN+T3WKEUo4CzwJHS1B2bsnH5vglHmbP+Y";
    };
    thebe = {
      hostNames = [ "thebe.localdomain" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOjnMhsh8PxlRW1tXYR4GjjDNa4J8os/4URkbD777JMg";
    };
    metis = {
      hostNames = [ "metis.localdomain" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAB6bFJpQteERsDDg7otkc42JOWXDZUA9WprQ/gnEiAK";
    };
  };

  sops.secrets.nix_build_ssh_key = { };

  # ---- Storage profile (OS SSD) --------------------------------------------
  # Stateful root (no impermanence — the NAS needs persistent state).
  jupiter.storage.profile = "stateful";
  jupiter.storage.disk = "/dev/disk/by-id/ata-CT500MX500SSD1_1921E206022D";

  # ---- ZFS NAS layer -------------------------------------------------------
  jupiter.nas.enable = true;

  # ---- Phase 2: CPU-tuned closure ------------------------------------------
  # DISABLED again 2026-08-16: no CI pipeline is currently delivering a
  # bdver4 closure (last successful push: f58fc16, 2026-08-06, which was
  # itself UNTUNED — microarch was commented out at that commit). With this
  # enabled and no substituter, every rebuild wants ~1830 local builds.
  # Europa runs the untuned cache.nixos.org closure (gen 79) for now.
  # jupiter.build.microarch = "bdver4"; # CI builds this host's closure with -march=bdver4

  # ---- nixpkgs overlays ----------------------------------------------------
  # bmake's `deptgt-interrupt` unit test is timing-sensitive (it asserts a
  # SIGINT yields exit 130) and flakes non-deterministically under load / when
  # the closure is microarch-tuned — on the first full tuned build it failed
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
  #
  # harmonia: ranged NAR requests always answer 200 instead of 206, so a
  # client that trusts Content-Range but checks status literally can accept
  # a truncated body as the full NAR -- silent corruption, not just a slow
  # cache miss. Fixed upstream in nix-community/harmonia#1139 (open,
  # mergeable, unmerged as of 2026-08-09). Carries the fix as a local patch
  # against the pinned harmonia-v3.1.0 source rather than pulling the PR's
  # branch: upstream main is 252 commits ahead of v3.1.0 (crate rename
  # harmonia_nar -> harmonia_file_nar and friends), so the PR's own diff
  # doesn't apply to this pin -- the one-line fix does, unchanged, since the
  # surrounding ranged-response code is untouched by that refactor. Drop
  # this overlay entry once a harmonia release containing #1139 is pulled
  # in via a nixpkgs bump.
  nixpkgs.overlays = [
    (_final: prev: {
      bmake = prev.bmake.overrideAttrs { doCheck = false; };
      postgresql_18 = prev.postgresql_18.overrideAttrs {
        doCheck = false;
        doInstallCheck = false;
      };
      harmonia = prev.harmonia.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./patches/harmonia-pr1139-ranged-206.patch ];
      });
    })
    # stdenv-wide doCheck=false overlay: REMOVED 2026-08-16. 7efc8c4
    # re-introduced it (europa-only) for the bdver4 local-build era, when
    # gmp/libmpc `make check` SIGILLed on this RDRAND-less Excavator CPU
    # under -march=bdver4 (gcc bug 116854). With microarch disabled nothing
    # builds locally anymore, and the overlay rewrites the output hash of
    # EVERY doCheck=true derivation (zlib and friends) all the way down —
    # measured 2026-08-16: 2308 unsubstitutable local builds vs ~70 without
    # it. That is exactly the buildability rule in CLAUDE.md: override the
    # one package that misbehaves (bmake/postgresql_18 above), never the
    # stdenv. If bdver4 local builds return, the fix is -mno-rdrnd in the
    # bootstrap gcc-wrapper, not silencing checkPhase fleet-wide.
  ];

  # ---- Networking ----------------------------------------------------------
  # Static identity below the DHCP pool so iSCSI/NFS clients have a stable
  # target. Uses enp2s0f1 (the live NIC — enp2s0f0 has no link on this unit).
  networking.useDHCP = false;
  networking.interfaces.enp2s0f1.ipv4.addresses = [
    {
      # Single source of truth: this interface IS what
      # jupiter.fleet.addresses.europa (modules/network/fleet.nix) points every
      # other host at.
      address = config.jupiter.fleet.addresses.europa;
      prefixLength = 24;
    }
  ];
  networking.defaultGateway = config.jupiter.fleet.addresses.gateway;

  # Static networking leaves no nameservers behind — common.nix defers DNS to
  # DHCP, which europa disabled above, so without this /etc/resolv.conf ends
  # up empty and the box can't resolve cache.nixos.org or any substituter.
  # The UniFi gateway resolves; 1.1.1.1 is the fallback if it's ever down.
  networking.nameservers = [
    config.jupiter.fleet.addresses.gateway
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
    # Only the leaf that differs from the module default. Everything else
    # (region 999/jupiter, STUN 3478, and crucially derp.urls' public DERP
    # fallback) comes from modules/services/headscale.nix. This block used to
    # restate the whole server attrset, which — under the old attrsOf option
    # shape — replaced the default outright and deleted `urls`, forcing all
    # relayed CI traffic through europa's own DERP. See that option's comment.
    derp.server.ipv4 = "157.85.248.45"; # neptune.jupiter.au
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
      {
        # nom-web (browser UI for jupiter-ci build logs) runs on callisto,
        # not here — cloudflared can proxy to any LAN host it can reach.
        # See modules/services/nom-web.nix / hosts/callisto/configuration.nix.
        hostname = "nom.jupiter.au";
        host = config.jupiter.fleet.addresses.callisto;
        port = 8092;
      }
      {
        # Home Assistant MCP server (mcp-ha-connect) on the HA box at 10.1.1.72.
        # Exposed so Aeon — running on GitHub Actions — can reach it; the
        # /private_<token> path is the shared secret and is NOT stored here
        # (it lives as the MCP_HA_URL secret in the Aeon repo).
        hostname = "ha-mcp.jupiter.au";
        host = config.jupiter.fleet.addresses.homeassistant;
        port = 9583;
      }
      {
        # AriaNg web UI for the aria2 download manager (see aria2.nix).
        hostname = "ariang.jupiter.au";
        port = 8083;
      }
      {
        # aria2 JSON-RPC. Cloudflare terminates TLS at the edge, so AriaNg
        # reaches this as wss://rpc.jupiter.au/jsonrpc (auth = RPC secret).
        # WebSocket upgrades are carried by cloudflared.
        hostname = "rpc.jupiter.au";
        port = 6800;
      }
    ];
  };
  services.harmonia.cache.enable = true;
  services.harmonia.cache.signKeyPaths = [ config.sops.secrets.harmonia_sign_key.path ];
  services.harmonia.cache.settings = {
    real_nix_store = "/nix/store";
    nix_db_path = "/nix/var/nix/db/db.sqlite";
    enable_compression = true;
    workers = 8;
    max_connection_rate = 512;
    priority = 30;
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
    # The WebUI is the device/folder management plane; exposing it to the
    # LAN is an explicit opt-in on this trusted home segment (the module
    # default is loopback-only).
    exposeLan = true;
  };

  # SMART monitoring on all attached disks (OS SSD + WD 18TB drives).
  jupiter.storage.smartMonitoring.enable = true;

  # Console screensaver — Matrix rain on tty1 Login stays on tty2 (Ctrl+Alt+F2).
  jupiter.consoleScreensaver.enable = true;

  # iSCSI target backing callisto's root filesystem — see hosts/callisto/configuration.nix).
  jupiter.services.iscsiTarget = {
    enable = true;
    targetIqn = "iqn.2026-07.au.jupiter:europa:callisto-root";
    initiatorIqn = "iqn.2026-07.au.jupiter:callisto";
  };

  # ---- jupiterOS Arcade (europa-side cartridge pipeline) ------------------
  # Bulk-stage No-Intro Nintendo cartridge ROMs via Minerva torrents, verify
  # against DATs with igir, scrape Pegasus metadata with Skyscraper, and emit
  # a periodic library inventory. Acquisition/verify are manual oneshots (no
  # timer — start them explicitly); scraping runs daily; inventory hourly
  # (arcade-inventory.nix: OnBootSec=2m, OnUnitActiveSec=1h — a full walk
  # stats every file on multi-TB trees, so it is deliberately not frequent).
  # Kiosks mount /tank/archive/retro/games/cartridge read-only.
  jupiter.services.romAcquire.enable = true;
  jupiter.services.romScraper.enable = true;
  jupiter.services.arcadeInventory.enable = true;

  # Suno account backup daemon — WAV masters + full per-clip metadata into
  # /tank/archive/suno. The suno_cookie sops secret must hold the Clerk
  # __client value (added to secrets/secrets.yaml, encrypted to europa's age
  # key) before this activates.
  jupiter.services.sunoBackup.enable = true;

  # Browser UI over that archive, on the LAN at http://10.1.1.2:8093. Indexes
  # the archive's meta.json files in memory (~40MB for the current ~18.7k
  # clips) and refreshes every 5m to pick up whatever the backfill has just
  # pulled down. LAN-only on purpose: it streams the 35-45MB lossless masters
  # directly, so putting it behind the Cloudflare Tunnel would want on-the-fly
  # transcoding first.
  jupiter.services.sunoWeb = {
    enable = true;
    openFirewall = true;
  };

  # aria2 + AriaNg web UI — LAN at http://10.1.1.2:8083
  jupiter.services.aria2 = {
    enable = true;
    downloadDir = "/tank/downloads";
    openFirewall = true;
    # AriaNg (web UI) defaults its RPC connection to rpc.jupiter.au:443, which
    # cloudflared tunnels to the local daemon (:6800); Cloudflare terminates
    # TLS / carries the WebSocket upgrade, so AriaNg talks wss://rpc.jupiter.au/jsonrpc.
    # The RPC secret is still entered once per browser (never embedded in the
    # served page — would leak the daemon's auth to anyone on the LAN).
    rpcHost = "rpc.jupiter.au";
    rpcProtocol = "wss";
    rpcWebPort = 443;
    # The arcade's rom-acquire submits its per-system torrents with
    # dir=<incomingDir>/<sys> (fire-and-forget via the JSON-RPC endpoint), so
    # the daemon needs the incoming root writable to resume partials in place.
    extraWritableDirs = [ config.jupiter.services.romAcquire.incomingDir ];
    # Enable IPv6 DHT (--enable-dht6). Bind to europa's stable global unicast
    # address (the mngtmpaddr EUI-64 one, not the rotating temporaries).
    dhtListenAddr6 = "2402:1060:2305:0:d267:26ff:fed3:b0a5";
  };

  # ---- sops secrets --------------------------------------------------------
  # harmonia_sign_key: private Nix binary-cache signing key for Harmonia
  # (generated via nix-store --generate-binary-cache-key).
  sops.secrets.harmonia_sign_key = { };
  # nix_build_ssh_key: private half of the dedicated builder keypair; the
  # public half is in callisto's root authorized_keys (buildMachines above).
  sops.secrets.nix_build_ssh_key = { };

  environment.systemPackages = with pkgs; [
    nix-output-monitor
  ];
}
