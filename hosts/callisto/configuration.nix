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
# The old design's callisto (diskless Postgres/Loki server for n8n + the HA
# recorder, PXE-served from ganymede) is NOT what this host is — different
# hardware, different role, reusing only the name.
#
# ---- Why iSCSI, not NFS (2026-07-24) ---------------------------------------
# This host previously kept a small NFS-backed /persist for just SSH host
# keys/logs, and even THAT burned a full session chasing initrd fragility
# (missing NIC driver, no DHCP client, no mount.nfs helper, no rpc.statd —
# see git history on this file) before being reverted to a plain,
# non-neededForBoot stage-2 mount. Root itself was never going anywhere near
# that path. iSCSI root uses a different, purpose-built NixOS mechanism
# instead (boot.iscsi-initiator, nixos/modules/services/networking/iscsi/
# root-initiator.nix) that nixpkgs ships specifically for booting / and /nix
# over iSCSI — not a hand-rolled mount. Its one hard requirement is the
# CLASSIC (non-systemd) stage-1 initrd: it asserts
# `!boot.initrd.systemd.enable`, because systemd-stage-1 doesn't support
# iSCSI yet. That's a real trade (this host loses systemd-stage-1's
# tooling), but it's the same initrd implementation every ordinary
# disk-based NixOS install has used for years — not the newer, thinner
# netboot-minimal environment that had "no hardware scan behind it" and
# caused the earlier pain.
#
# A useful side effect: since root is now a real persistent filesystem
# instead of a tmpfs squashfs overlay, sops-nix can decrypt secrets at
# activation like on any other host. The "sops can't decrypt at runtime
# here" gap this host used to carry is closed by this change, not worked
# around — no impermanence/NFS-persist plumbing needed at all anymore.
{
  imports = [
    ../../modules/common.nix
    ../../modules/services/console-screensaver.nix
    ../../modules/services/mqtt.nix
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

  # Root over iSCSI: a plain ext4 filesystem on the whole LUN. NO ZFS layer
  # — europa already runs ZFS on the backing tank, and stacking ZFS on a
  # network block device is both redundant and fragile (ZFS expects direct
  # disk access and deadlocked the boot when tried). ext4 on the LUN is the
  # simple, correct design: the LUN is a block device, mkfs.ext4 it, mount
  # it. No pool, no pool-name collision with europa's own rpool, no rescue
  # rename step. The LUN is used whole (no GPT partition) so by-path exposes
  # only the single lun-0 device to mount.
  #
  # Same by-path device format as before — systemd-udevd's path_id
  # (handle_scsi_iscsi()) generates ip-<addr>:<port>-iscsi-<iqn>-lun-<N>
  # for the iSCSI SCSI device, deterministic from the portal/target above.
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

  # Don't add a build-machine entry pointing at itself.
  jupiter.core.buildMachines.enable = false;

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
  # Risk consideration: 64GB RAM. Worst-case -j6 linker memory for
  # LLVM-class packages is ~12-24GB; the box has 60+GB free in steady
  # state, so no OOM exposure at this setting. No swap — root now persists
  # on a disk-backed ext4 filesystem rather than tmpfs, but that headroom
  # math was never about tmpfs pressure in the
  # first place, it's about the build's own working set vs. RAM.
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
  # ROADMAP ENTRY ONLY — DO NOT REBUILD CALLISTO LOCALLY BEFORE PALLENE:
  # setting this option tags every derivation in callisto's closure with
  # requiredSystemFeatures=["gccarch-skylake"], which invalidates
  # cache.nixos.org for it. Pallene (modules/services/build-server.nix,
  # which now lists callisto in `hosts` and "skylake" in `microarchs`) must
  # build and push this closure to attic FIRST. Only then can callisto
  # safely `nixos-rebuild` — and even then, only if attic already has the
  # paths.
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
  # monitor is plugged into this host. Same module as europa; Nice=19 is
  # baked into modules/services/console-screensaver.nix itself (not a
  # per-host override), so the eye-candy always yields to real build work
  # here too.
  jupiter.consoleScreensaver.enable = true;

  # ---- MQTT broker (moved from amalthea 2026-07-24) -----------------------
  # The fleet's mosquitto broker: every kiosk's ha-agent publishes here, and
  # an external Home Assistant instance subscribes as the `homeassistant`
  # user. It used to run on amalthea, coupling fleet infrastructure to a
  # kiosk's impermanent/appliance lifecycle; callisto is a better home now
  # that it has a persistent root (see the iSCSI comment above sops can
  # decrypt at activation here too). Kiosks reach it at the static
  # 10.1.1.3 DHCP reservation (modules/desktop/tcxwave-kiosk.nix's
  # mqttHost default) — same address build-machines.nix already dials, since
  # callisto has no DNS/mDNS resolution yet.
  #
  # NOT auto-covered by anything imported above: unlike the kiosks (which
  # get mqtt_ha_linux_agent via tcxwave-kiosk.nix), callisto needs both
  # secrets declared explicitly here.
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
}
