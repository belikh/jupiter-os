{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

# Diskless netboot compute node — PXE-booted from europa (jupiter.pxe). No
# local disk: the box has repeatedly destroyed NVMe drives, so it's run
# fully diskless/in-RAM instead (64GB RAM gives plenty of headroom for a
# tmpfs-backed store overlay).
#
# Role: the fleet's shared Nix remote builder (jupiter.core.buildMachines,
# in modules/core/build-machines.nix). HP EliteDesk 800 G4 DM with an
# i5-8500T (Coffee Lake, 6c/6t, no HT) + 64GB RAM — dwarfs every other
# registered host's hardware, so every host delegates eligible builds here
# instead of building locally.
#
# Live at 10.1.1.3 (UniFi DHCP reservation, MAC c4:65:16:b8:76:03 —
# see modules/core/build-machines.nix). Booted kexec-style from the PXE
# chain europa serves (flake.nix's pxeModule); the running toplevel carries
# a "jupiter-kexec" suffix and /proc/cmdline shows root=fstab.
#
# The old design's callisto (diskless Postgres/Loki server for n8n + the HA
# recorder, PXE-served from ganymede) is NOT what this host is — different
# hardware, different role, reusing only the name and the diskless-netboot
# mechanics. PXE now lives on europa instead of ganymede (ganymede isn't
# registered), matching the cloudflareTunnel-on-europa deviation.
#
# ---- Persistent state (NFS-backed) -----------------------------------------
# Despite being diskless, callisto gets real persistence: europa exports a
# per-host ZFS dataset (tank/services/callisto, created by
# modules/storage/zfs-nas.nix) back to callisto over NFS at /persist, and
# impermanence (modules/core/impermanence.nix) bind-mounts the
# needed-but-not-all-of-/etc/ssh paths from it. That gives callisto a
# stable SSH host key across closure changes (so other hosts could
# eventually pin it via publicHostKey) AND lets sops-nix decrypt runtime
# secrets normally — closing both gaps the previous "all in RAM" model had.
# /nix/store itself stays in tmpfs (NFS would be wrong: too slow, and nix
# db needs transactional consistency). What's persisted: SSH host keys,
# /etc/machine-id, /var/log, /var/lib/{nixos,sops-nix,systemd/coredump} —
# the same set the kiosks keep on their local /persist, just over the wire.
{
  imports = [
    (modulesPath + "/installer/netboot/netboot-minimal.nix")
    ../../modules/common.nix
    ../../modules/services/console-screensaver.nix
  ];

  networking.hostName = "callisto";

  # Diskless: no ZFS use at all, so don't build the zfs kernel module for
  # this kernel. common.nix's storage profile stays at its "none" default
  # (no disko, no ZFS root) — this override is belt-and-suspenders should
  # anything else default it on.
  boot.supportedFilesystems.zfs = lib.mkForce false;

  # Ensure the netboot image is fully copied to RAM on boot.
  boot.kernelParams = [ "copytoram" ];

  # Don't add a build-machine entry pointing at itself.
  jupiter.core.buildMachines.enable = false;

  # ---- NFS-backed /persist (from europa's tank/services/callisto) ----------
  # `_netdev` makes systemd wait for network before mounting; `noac` trades
  # a small perf hit for stronger attribute-cache coherency with the NFS
  # server (matters for /etc/ssh bind-mounts: stale attribute cache has
  # been observed to make ssh-keygen's "key exists, refusing to overwrite"
  # check lie). `timeo=14,retrans=5` is the standard tolerant-on-LAN tuning.
  fileSystems."/persist" = {
    device = "10.1.1.2:/tank/services/callisto";
    fsType = "nfs";
    # neededForBoot is mandatory for any filesystem impermanence bind-mounts
    # from (NixOS asserts this at eval time).
    neededForBoot = true;
    options = [
      "rw"
      "_netdev"
      "noac"
      "noatime"
      "timeo=14"
      "retrans=5"
    ];
  };

  # Impermanence bind-mounts the persistent paths (SSH host keys,
  # /etc/machine-id, /var/log, /var/lib/nixos, /var/lib/sops-nix) out of
  # /persist. On first boot impermanence copies the squashfs-baked values
  # into /persist, so the keys it ships with today become the persistent
  # identity going forward (no separate init/keygen step needed).
  # persistAdminHome=false: this is an appliance, not an interactive host.
  jupiter.core.impermanence = {
    enable = true;
    persistAdminHome = false;
  };

  # ---- Build daemon tuning for the shared-builder workload ----------------
  # callisto's actual workload is the OPPOSITE of pallene's
  # (modules/services/build-server.nix). Pallene does full-closure
  # rebuilds-from-scratch: wide shallow dependency graph, many small
  # packages, so pallene correctly picks cores=1 + max-jobs=auto(N) — full
  # utilization through cross-package parallelism, the standard Hydra
  # build-farm pattern.
  #
  # callisto is a SHARED incremental builder for the fleet: when any host
  # does `nixos-rebuild`, only the few packages that actually changed get
  # dispatched here (the rest substitute from cache.nixos.org / attic). Low
  # concurrency, larger per-package work. For that shape, cores=N +
  # max-jobs=1 wins: each derivation gets all 6 cores for its internal
  # `make -j$NIX_BUILD_CORES`, so even single big packages (a stale LLVM, a
  # kernel bump, a fresh rustc) finish fast instead of compiling
  # single-threaded while the other 5 cores sit idle waiting for the next
  # dispatch.
  #
  # Risk consideration: 64GB RAM, no swap (diskless, tmpfs /nix/store).
  # Worst-case -j6 linker memory for LLVM-class packages is ~12-24GB; the
  # box has 60+GB free in steady state, so no OOM exposure at this setting.
  # If a future workload ever runs concurrent multi-host dispatches that
  # genuinely need cross-package parallelism instead, raise max-jobs and
  # lower cores in lockstep (and mirror the change in
  # modules/core/build-machines.nix's maxJobs, which tells dispatchers how
  # much concurrent work callisto will accept).
  nix.settings.cores = 6;
  nix.settings.max-jobs = 1;

  # Advertise capability to BUILD other hosts' microarch-tuned derivations
  # without tuning callisto's own closure (no jupiter.build.microarch here —
  # callisto itself stays on the portable baseline). Without the matching
  # gccarch-<arch> feature, Nix refuses to even attempt a tagged derivation
  # here regardless of whether the CPU could run it — same mechanism as
  # pallene's jupiter.services.buildServer.microarchs.
  #
  # CPU confirmed 2026-07-20: i5-8500T is Coffee Lake, a strict ISA superset
  # of Skylake — so the gccarch-skylake advert is safe both ways (callisto
  # can compile skylake-tagged code AND run it in any checkPhase). This is
  # what makes the eventual kiosk tuning (also skylake, i5-6300U) safe to
  # dispatch here.
  nix.settings.system-features = lib.mkAfter [
    "gccarch-btver2"
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

  # ---- Roadmap: tune callisto's own closure for its CPU -------------------
  # i5-8500T is Coffee Lake, which GCC targets as `skylake` (Coffee Lake is
  # Skylake-refresh at the compiler/code-scheduling level — same ISA, same
  # pipeline model; `-march=skylake` produces code that's both correct on
  # and optimally scheduled for this part).
  #
  # ROADMAP ENTRY ONLY — DO NOT REBUILD CALLISTO LOCALLY BEFORE PALLEN:
  # setting this option tags every derivation in callisto's closure with
  # requiredSystemFeatures=["gccarch-skylake"], which invalidates
  # cache.nixos.org for it. Pallene (modules/services/build-server.nix,
  # which now lists callisto in `hosts` and "skylake" in `microarchs`) must
  # build and push this closure to attic FIRST. Only then can callisto
  # safely `nixos-rebuild` — and even then, only if attic already has the
  # paths (callisto is diskless: tmpfs /nix/store with no swap, so a local
  # from-scratch rebuild of even a medium package would OOM the box).
  # Verify pre-deploy with `nix path-info --substituters
  # http://10.1.1.2:8080/jupiter-os <toplevel>` from callisto — every path
  # must resolve from attic before `switch`.
  #
  # DISABLED 2026-07-22: this was committed ahead of pallene actually doing
  # the required build+push. Consequence discovered during europa's PXE
  # bring-up: europa's netboot.ipxe embeds callisto's system.build.toplevel
  # path (for the kexec init= cmdline), so ANYTHING that evaluates
  # nixosConfigurations.callisto — including an unrelated europa rebuild —
  # was forced to build callisto's *entire* skylake-tagged closure from
  # scratch, since nothing skylake-tagged exists in attic or cache.nixos.org.
  # Re-enable only after pallene has actually pushed a skylake closure.
  # jupiter.build.microarch = "skylake";

  # Console screensaver — Matrix rain on tty1 for the (rare) moments a
  # monitor is plugged into this diskless box. Same module as europa; Nice=19
  # is baked into modules/services/console-screensaver.nix itself (not a
  # per-host override), so the eye-candy always yields to real build work
  # here too.
  jupiter.consoleScreensaver.enable = true;
}
