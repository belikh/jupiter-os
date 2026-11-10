---
name: nixos-hosts
description: Assemble a NixOS machine — `nixosSystem`, `hardware-configuration.nix`, disko, impermanence, bootloaders, `stateVersion`. Use when creating a host, partitioning disks, setting up boot, or first-installing NixOS.
---

# Assembling a NixOS host

A host is a `nixosSystem` invocation combining a hardware description, a disk
layout, a bootloader, users, and whatever modules the machine needs. The two
things every host must get right: `system.stateVersion` (set once, never
changed) and the filesystem/boot pair (a config that evaluates but has no boot
entry is not a host).

## Workflow

1. **Define the identity.** Add the host to the flake's `nixosConfigurations`
   with `nixpkgs.lib.nixosSystem { modules = [ ./configuration.nix … ];
   specialArgs = …; }`. Done when `nix flake check --no-build` recognises it.
2. **Capture the hardware.** Run `nixos-generate-config --root /mnt` on the
   target (or in the installer) to produce `hardware-configuration.nix`:
   platform, kernel modules, CPU microcode, and the current `fileSystems`.
   Treat it as generated output — future runs overwrite edits. Done when the
   file exists and matches the machine.
3. **Decide the disk layout.** Straightforward: keep the generated
   `fileSystems`. Declarative: use disko and regenerate with
   `--no-filesystems` so there is exactly one source of truth. Optional:
   erase-on-reboot via impermanence. Done when mountpoints are complete,
   including `/boot`, and nothing is declared twice. See
   `references/disks-and-impermanence.md`.
4. **Set up boot.** Pick systemd-boot (UEFI) or GRUB (includes BIOS), mount the
   ESP appropriately, and decide `configurationLimit`. Done when the loader
   package and entries are generated (a build produces
   `system.build.installBootLoader` input). See `references/bootloaders.md`.
5. **Pin `system.stateVersion`.** Set it to the release you are installing
   from (`"26.05"` for NixOS 26.05) and never change it afterwards. Upgrading
   changes the channel/branch pin, not this value. Leaving it unset warns and
   silently defaults to the current release.
6. **Add users and secrets.** Passwords only as `hashedPasswordFile` sourced
   from the secret manager — see `nixos-secrets`.
7. **Test before installing.** `nixos-rebuild build` for the closure, then
   `nixos-rebuild build-vm` and boot the VM; a config that cannot boot in QEMU
   will not boot on metal.
8. **Install.** `nixos-install` for a running installer; `disko-install` to
   combine partitioning and install; `nixos-anywhere` to install a remote
   machine over SSH (it kexecs an installer and wipes the target).
9. **Verify on first boot.** `readlink /run/current-system`,
   `systemctl is-system-running`, `nixos-rebuild list-generations`. Done when
   the running closure matches what you built and the system reaches
   `running`.

## Essentials

- **`nixosSystem` arguments:** `modules` (highest-priority module list),
  `specialArgs`, and historically `system`/`pkgs`. The platform now comes from
  `nixpkgs.hostPlatform`, which generated `hardware-configuration.nix` sets —
  do not set `system` in two places.
- **`system.stateVersion` is a data-format gate, not a version pin.** It
  selects defaults for packages whose on-disk format cannot migrate silently
  (PostgreSQL major, Nextcloud, etc.). Changing it after install can trigger
  migrations or break services; it does not upgrade anything by itself.
- **ZFS and kernels:** ZFS supports specific kernel versions. Use the stock
  `linuxPackages` set that nixpkgs pairs with ZFS — a binary cache has it
  built — rather than chasing `linuxPackages_latest` on a ZFS host, where the
  ZFS module may not evaluate or build. (See https://wiki.nixos.org/wiki/ZFS,
  accessed 2026-09-30.)
- **Erase-on-reboot is opt-in and high-stakes.** With impermanence, anything
  not under a persistence path is gone after reboot. Plan the persisted set
  before enabling it, and re-read `references/disks-and-impermanence.md`.

## Pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| evaluation missing `fileSystems` or duplicate definitions | disko module plus generated `fileSystems` both present | regenerate hardware config with `--no-filesystems` |
| machine powers on to an old OS or no entry | bootloader not installed / EFI variables not written | check `boot.loader.*` and `efi.canTouchEfiVariables`; see `references/bootloaders.md` |
| service data reset/lost after upgrade | `system.stateVersion` changed | restore the original value |
| files silently vanish on reboot | impermanence enabled without a persistence entry | add the path (or `neededForBoot`) and re-test in a VM |
| won't boot after a config change | kernel/initrd/bootloader changes need a reboot | `nixos-rebuild boot` then reboot, watch the console |
| VM test differs from metal | missing kernel module/firmware not exercised in QEMU | test with the same config on the target, or add the module |

## References

- `references/disks-and-impermanence.md` — disko device trees, apply modes,
  remote install with nixos-anywhere, impermanence persistence maps and their
  classic forgotten paths.
- `references/bootloaders.md` — systemd-boot vs GRUB, EFI specifics,
  `configurationLimit`, generation entries and boot-time rollback.

## Sources

- NixOS manual, installation and changing configuration: https://nixos.org/manual/nixos/stable/ (accessed 2026-09-30)
- `system.stateVersion` semantics: https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion (accessed 2026-09-30)
- disko: https://github.com/nix-community/disko (accessed 2026-09-30)
- impermanence: https://github.com/nix-community/impermanence (accessed 2026-09-30)
- nixos-anywhere: https://github.com/nix-community/nixos-anywhere (accessed 2026-09-30)
- ZFS on NixOS: https://wiki.nixos.org/wiki/ZFS (accessed 2026-09-30)
