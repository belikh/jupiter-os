# Bootloaders and boot-time rollback

## Choose one

| | systemd-boot | GRUB |
|---|---|---|
| Firmware | UEFI only | BIOS and UEFI |
| Config | `boot.loader.systemd-boot.enable = true;` | `boot.loader.grub.enable = true;` |
| Device | ESP at `/boot` (mount it in `fileSystems`) | BIOS: `boot.loader.grub.devices = [ "/dev/disk/by-id/…" ];` UEFI: `device = "nodev"; efiSupport = true;` |
| EFI vars | set `boot.loader.efi.canTouchEfiVariables = true;` to register an entry; leave `false` for removable/self-contained installs | `efiInstallAsRemovable = true;` for NVRAM-independent |
| Entries kept | `boot.loader.systemd-boot.configurationLimit` (default: unlimited) | `boot.loader.grub.configurationLimit` (default: 100 — GRUB misbehaves with too many) |

Minimal systemd-boot host:

```nix
{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  fileSystems."/boot" = { device = "/dev/disk/by-id/…-part1"; fsType = "vfat"; };
}
```

Two security-relevant defaults: systemd-boot's editor (`boot.loader.systemd-boot.editor = true`)
lets anyone append `init=/bin/sh` at the boot menu — set `false` on machines
with physical strangers. `configurationLimit` bounds how many generations stay
bootable; the rest are only reclaimable by garbage collection.

## Generations and rollback

- Every `switch`/`boot` creates a generation:
  `/nix/var/nix/profiles/system-<N>-link`, with `system` pointing at the
  current one.
- **Live rollback:** `nixos-rebuild switch --rollback` re-activates the
  previous generation.
- **Boot-time rollback:** pick an older entry in the boot menu
  (systemd-boot lists them; GRUB has "NixOS - All configurations"), boot it,
  then make it permanent with
  `/run/current-system/bin/switch-to-configuration boot` (run as root) or fix
  things and switch forward again.
- **Test generations** (`nixos-rebuild test`) never get a boot entry and revert
  on reboot — deliberate for experiments.
- Garbage collection removes old generations only when they are no longer GC
  roots; `nix-collect-garbage -d` deletes roots and with them your rollback
  targets. Keep at least one known-good generation until the new one is
  verified.
- Kernel, initrd, and bootloader changes take effect at **reboot**;
  `nixos-rebuild boot` + reboot is the safe order for those, so a failed boot
  drops you back to the previous generation instead of a half-activated
  system.

## Boot entries and what they point at

Loader entries name a top-level closure (`nixos-system-<host>-<version>`),
which contains kernel, initrd, and init. When you delete generations you must
rebuild (`boot`/`switch`) for the loader config to drop the entries. On NixOS
26.11+, systemd-boot entries are named `nixos-<content-hash>.conf` and
automatic boot assessment is available via
`boot.loader.systemd-boot.bootCounting` (a failing boot demotes the entry).

## Verification

- After a rebuild intended to persist, check the loader entry exists:
  `ls /boot/loader/entries` (systemd-boot) and that `system` points where you
  think: `readlink /nix/var/nix/profiles/system`.
- After reboot, `readlink /run/current-system` must equal the closure you
  built; otherwise you booted an older generation.
- `nixos-rebuild list-generations` shows dates, kernel, and which generation
  is current.

## Sources

- NixOS manual, boot loader configuration and "NixOS Boot Entries": https://nixos.org/manual/nixos/stable/#sec-boot-loader (accessed 2026-09-30)
- NixOS manual, rollback: https://nixos.org/manual/nixos/stable/#sec-rollback (accessed 2026-09-30)
- nixpkgs bootloader modules: `nixos/modules/system/boot/loader/` (systemd-boot, grub) (accessed 2026-09-30)
