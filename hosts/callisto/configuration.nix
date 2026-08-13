{
  config,
  lib,
  pkgs,
  ...
}:

# Compute node with no local disk — HP EliteDesk 800 G4 DM, i5-8500T
# (Coffee Lake, 6c/6t, no HT) + 64GB RAM. The box has repeatedly destroyed
# local NVMe drives, so it has none; root instead lives on an ext4
# filesystem carried over iSCSI from europa's tank/services/callisto-root
# zvol (modules/services/iscsi-target.nix). PXE (europa, jupiter.pxe) still
# hands off the kernel+initrd exactly as before — only what happens after
# the kernel starts has changed, from "unpack a RAM-resident squashfs" to
# "iSCSI-login, then mount a real ext4 root over the network".
#
# Role: the fleet's shared Nix remote builder (jupiter.core.buildMachines,
# in modules/core/build-machines.nix). Dwarfs every other registered host's
# hardware, so every host delegates eligible builds here instead of
# building locally.
#
# Live at 10.1.1.3 (UniFi DHCP reservation, MAC c4:65:16:b8:76:03 — see
# modules/core/build-machines.nix).
#
{
  imports = [
    ../../modules/common.nix
    ../../modules/services/console-screensaver.nix
    ../../modules/services/mqtt.nix
    # Tailscale client for Jupiter tailnet
    ../../modules/services/tailscale.nix
    # Aeon autonomous agent framework dashboard
    ../../modules/services/aeon.nix
    # nom-web: browser UI for jupiter-ci build logs
    ../../modules/services/nom-web.nix
  ];

  networking.hostName = "callisto";
  # Stable per-host 8-char hex. Not currently required — callisto's root is
  # ext4, not ZFS, so nothing here actually consumes this — kept set anyway
  # since it's harmless and cheap insurance if a ZFS-backed filesystem is
  # ever added on this host later.
  networking.hostId = "ca11157c";

  # ---- Root over iSCSI -----------------------------------------------------
  # boot.iscsi-initiator (nixos/modules/services/networking/iscsi/root-initiator.nix)
  # HARD-asserts `!boot.initrd.systemd.enable` — it uses preLVMCommands/
  # extraUtilsCommands, which the systemd-stage-1 initrd doesn't implement
  # at all ("systemd stage 1 does not support iscsi yet" is its own literal
  # assertion message). This is the one non-optional trade of this whole
  # design: callisto loses systemd-stage-1's tooling in exchange for a
  # working iSCSI root, on this one host only.
  boot.initrd.systemd.enable = false;

  # The module also forces networking.useNetworkd = true and
  # networking.useDHCP = false itself (unconditional assignments, not
  # mkDefault) — don't set those separately here, they'd conflict. It adds
  # the iscsi_tcp kernel module, the iscsid/iscsiadm binaries, and
  # boot.initrd.network.enable = true (generic initrd DHCP, the classic-initrd
  # equivalent of what systemd-stage-1's network.enable does) on its own.
  # The only thing left to us is the NIC driver, which (unlike
  # netboot-minimal's RAM-resident environment, which had "no hardware scan
  # behind it") this classic initrd can autoload via udev the normal way —
  # same mechanism every disk-based NixOS install already relies on.
  boot.initrd.availableKernelModules = [ "e1000e" ]; # onboard Intel I219-LM
  boot.iscsi-initiator = {
    name = "iqn.2026-07.au.jupiter:callisto";
    discoverPortal = "10.1.1.2:3260";
    target = "iqn.2026-07.au.jupiter:europa:callisto-root";
  };

  
  fileSystems."/" = {
    device = "/dev/disk/by-path/ip-10.1.1.2:3260-iscsi-iqn.2026-07.au.jupiter:europa:callisto-root-lun-0";
    fsType = "ext4";
    options = [ "relatime" ];
  };

  # PXE (europa's jupiter.pxe) hands off the kernel+initrd directly — this
  # host's own firmware boot menu / EFI NVRAM is never consulted, so
  # systemd-boot's *files* landing on the ESP are inert (harmless, just
  # unused). The provisioning install must therefore run with
  # `nixos-install --no-bootloader` (see docs/callisto-iscsi-root-provisioning.md
  # Stage 2): systemd-boot's installer runs `check-mountpoints`, which HARD-fails
  # when /boot isn't a mounted ESP, and the iSCSI LUN is a bare zvol with no
  # ESP — so the bootloader step must be skipped, not run. Actually touching
  # EFI NVRAM is the dangerous part regardless: the provisioning install runs
  # FROM europa against the zvol as a local block device, and EFI NVRAM belongs
  # to whichever physical machine runs the install (europa), not to the target
  # disk — leaving canTouchEfiVariables at common.nix's default would try to
  # rewrite EUROPA's own boot entries during that cross-machine install.
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  boot.loader.systemd-boot.enable = false; # iSCSI LUN has no ESP; PXE boots kernel+initrd directly
  boot.loader.grub.enable = false; # no bootloader on iSCSI LUN

  # ---- Build daemon tuning for the shared-builder workload ----------------
  # callisto is a SHARED incremental builder for the fleet: when any host
  # does `nixos-rebuild`, only the few packages that actually changed get
  # dispatched here (the rest substitute from cache.nixos.org / Harmonia). Low
  # concurrency, larger per-package work. For that shape, cores=N +
  # max-jobs=1 wins: each derivation gets all 6 cores for its internal
  # `make -j$NIX_BUILD_CORES`, so even single big packages (a stale LLVM, a
  # kernel bump, a fresh rustc) finish fast instead of compiling
  # single-threaded while the other 5 cores sit idle waiting for the next
  # dispatch.
  #
  # Risk consideration: 64GB RAM. Worst-case -j6 linker memory for
  # LLVM-class packages is ~12-24GB; the box has 60+GB free in steady
  # state, so no OOM exposure at this setting. No swap — root now persists
  # on a disk-backed ext4 filesystem rather than tmpfs, but that headroom
  # math was never about tmpfs pressure in the
  # first place, it's about the build's own working set vs. RAM.
  nix.settings.cores = 6;
  nix.settings.max-jobs = 1;

  # Advertise capability to BUILD other hosts' microarch-tuned derivations.
  # callisto's own closure is ALSO skylake-tuned now (jupiter.build.microarch
  # = "skylake" below), so this advert matches its own tag. Without the
  # matching gccarch-<arch> feature, Nix refuses to even attempt a tagged
  # derivation here regardless of whether the CPU could run it.
  #
  # CPU confirmed 2026-07-20: i5-8500T is Coffee Lake, a strict ISA superset
  # of Skylake — so the gccarch-skylake advert is safe both ways (callisto
  # can compile skylake-tagged code AND run it in any checkPhase). This is
  # what makes the kiosk tuning (also skylake, i5-6300U) safe to dispatch
  # here.
  nix.settings.system-features = lib.mkAfter [
    "gccarch-bdver4"
    "gccarch-skylake"
    "big-parallel"
  ];

  # Dedicated key for fleet hosts to authenticate as root here for build
  # delegation (modules/core/buildMachines.nix). Public key only — not a
  # secret. Merges with common.nix's io-derived root key (NixOS concatenates
  # list-type options across modules), so admin SSH access is unaffected.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILv1nEsuHqlA1ykn1p8wZmhhv1Y77cBxhgu2tAO3DhlP jupiter-fleet-nix-build"
  ];

  jupiter.build.microarch = "skylake";

  sops.secrets.tailscale_fleet_authkey = { };
  jupiter.services.tailscale = {
    enable = true;
    serverUrl = "https://neptune.jupiter.au:8080";
    tags = [ "tag:fleet" ];
    acceptRoutes = true;
    authKeyFile = config.sops.secrets.tailscale_fleet_authkey.path;
  };

  jupiter.consoleScreensaver.enable = true;

  sops.secrets.mqtt_homeassistant = { };
  sops.secrets.mqtt_ha_linux_agent = { };

  jupiter.services.mqtt = {
    enable = true;
    users = {
      homeassistant = {
        passwordFile = config.sops.secrets.mqtt_homeassistant.path;
        acl = [ "readwrite #" ];
      };
      ha-linux-agent = {
        passwordFile = config.sops.secrets.mqtt_ha_linux_agent.path;
        acl = [
          "readwrite homeassistant/#"
          "readwrite ha-linux-agent/#"
        ];
      };
    };
  };

  # ---- Local model server (jupiter.services.llm) ---------------------------
  # Serves Qwen3-Coder-30B-A3B (a 3B-active MoE — the sweet spot for this
  # CPU-only, 6-thread, no-AVX-512 box with ~62Gi RAM) via llama-server on
  # port 8081. This is the fleet's only model server: every other host's crush
  # dials it over the LAN (modules/common.nix defaults clientUrl to callisto's
  # static IP). We bind 0.0.0.0 + open the firewall for those hosts, then pin
  # our own clientUrl back to localhost so crush here skips the LAN hop. It
  # WILL share the CPU with the fleet builder workload (nix builds already use
  # all 6 threads), so nThreads is kept at 6 but is operator-tunable down if
  # builds suffer. The GGUF is self-downloaded on first start
  # (--hf-repo/--hf-file) into llama-server's StateDirectory; nothing
  # model-sized enters the nix store.
  jupiter.services.llm.enable = true;
  jupiter.services.llm.host = "0.0.0.0";
  jupiter.services.llm.exposeLan = true;
  jupiter.services.llm.clientUrl = "http://127.0.0.1:8081";

  # ---- iGPU offload for the model server (Vulkan, UHD 630) -----------------
  # i5-8500T's integrated UHD Graphics 630 is Gen9.5 (PCI 8086:3e92) — a
  # sideline compute unit distinct from the 6 CPU cores the build-server and
  # llama-server workloads already compete over, so offloading here doesn't
  # take capacity from either. Picked Vulkan over SYCL/oneAPI for this specific
  # part: SYCL's biggest wins are on Xe/Arc-class silicon, and Gen9.5 doesn't
  # clear the extra oneAPI toolchain weight worth carrying. Mesa ships the ANV
  # Vulkan ICD itself, so `hardware.graphics.enable` (below) is sufficient —
  # no separate Intel compute-runtime package needed.
  #
  # `n-gpu-layers` uses llama.cpp's own convention of "any number ≥ the
  # model's real layer count" to mean "offload everything" (Qwen3-Coder-30B-A3B
  # has 48); 999 is comfortably past that. Operator-tunable down (or back to 0)
  # if benchmarking shows offload losing to CPU-only on this box, same as
  # nThreads above.
  jupiter.services.llm.package = pkgs.llama-cpp.override { vulkanSupport = true; };
  jupiter.services.llm.gpuLayers = 999;

  hardware.graphics.enable = true;

  # Vulkan / Mesa diagnostics (vulkaninfo) — same tool modules/gaming/console.nix
  # installs for the same reason, kept independent here since that module is
  # gamescope-specific and not something callisto should pull in.
  environment.systemPackages = [ pkgs.vulkan-tools ];

  # ---- Aeon autonomous agent framework --------------------------------------
  # Runs the aeon dashboard (Next.js on port 5555, bound 0.0.0.0 for LAN +
  # Tailscale access). The dashboard manages belikh/agent (a public fork of
  # aeonfun/aeon) via the `gh` CLI — all config (skills, schedules,
  # STRATEGY.md, SOUL.md, API keys, notifications) is done through the web UI.
  # GitHub Actions runs skills on cron in the fork's repo (public = unlimited
  # free Actions minutes). See modules/services/aeon.nix.
  sops.secrets.aeon_gh_token = { };

  jupiter.services.aeon = {
    enable = true;
    repoUrl = "github:belikh/aeon";
    ghTokenFile = config.sops.secrets.aeon_gh_token.path;
    host = "0.0.0.0";
    exposeLan = true;
  };

  # ---- nom-web: browser UI for ci-distributed.yml's build logs -------------
  # Reads europa's /var/log/jupiter-ci over NFS (export in
  # modules/storage/nas-nfs.nix); `soft` so a dead europa doesn't hang the
  # service. Reached publicly at nom.jupiter.au via europa's Cloudflare
  # Tunnel (extraIngress in hosts/europa/configuration.nix), so the port only
  # needs to be open to the LAN, not the internet.
  fileSystems."/mnt/jupiter-ci-logs" = {
    device = "10.1.1.2:/var/log/jupiter-ci";
    fsType = "nfs";
    options = [
      "ro"
      "noatime"
      "soft"
      "timeo=50"
      "retrans=2"
    ];
  };

  jupiter.services.nomWeb = {
    enable = true;
    openFirewall = true;
  };
}
