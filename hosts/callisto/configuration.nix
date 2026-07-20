{
  config,
  lib,
  modulesPath,
  ...
}:

# Diskless netboot compute node — PXE-booted from europa (jupiter.pxe). No
# local disk: the box has repeatedly destroyed NVMe drives, so it's run
# fully diskless/in-RAM instead (64GB RAM gives plenty of headroom for a
# tmpfs-backed store overlay).
#
# Role: the fleet's shared Nix remote builder (jupiter.core.buildMachines,
# in modules/core/build-machines.nix). i5 + 64GB RAM dwarfs every other
# registered host's hardware, so every host delegates eligible builds here
# instead of building locally.
#
# Registered CI-green only, same as metis/adrastea: no physical netboot test
# yet. The old design's callisto (diskless Postgres/Loki server for n8n +
# the HA recorder, PXE-served from ganymede) is NOT what this host is —
# different hardware, different role, reusing only the name and the
# diskless-netboot mechanics. PXE now lives on europa instead of ganymede
# (ganymede isn't registered), matching the cloudflareTunnel-on-europa
# deviation.
#
# KTD: diskless means no persistent /etc/ssh host key, so (a) sops-nix can't
# derive an age key at runtime — common.nix's `sops.secrets.io_password` is
# activation-time only (per CLAUDE.md, sops never touches eval/build/CI) so
# this doesn't block registration, but runtime secret provisioning here is
# unsolved and must be worked out before any real physical boot; and (b) the
# SSH host key changes every boot, so the other hosts' build-machine SSH
# config disables host-key pinning for callisto specifically (see
# modules/core/build-machines.nix) — there's no stable key to pin.
{
  imports = [
    (modulesPath + "/installer/netboot/netboot-minimal.nix")
    ../../modules/common.nix
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

  # Advertise capability to BUILD other hosts' microarch-tuned derivations
  # without tuning callisto's own closure (no jupiter.build.microarch here —
  # callisto itself stays on the portable baseline). Without the matching
  # gccarch-<arch> feature, Nix refuses to even attempt a tagged derivation
  # here regardless of whether the CPU could run it — same mechanism as
  # pallene's jupiter.services.buildServer.microarchs.
  # TODO: confirm the i5's exact model/core count and set maxJobs/cores in
  # modules/core/build-machines.nix accordingly once known.
  nix.settings.system-features = lib.mkAfter [
    "gccarch-btver2"
    "gccarch-skylake"
    "big-parallel"
  ];

  # Dedicated key for fleet hosts to authenticate as root here for build
  # delegation (modules/core/build-machines.nix). Public key only — not a
  # secret. Merges with common.nix's io-derived root key (NixOS concatenates
  # list-type options across modules), so admin SSH access is unaffected.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILv1nEsuHqlA1ykn1p8wZmhhv1Y77cBxhgu2tAO3DhlP jupiter-fleet-nix-build"
  ];
}
