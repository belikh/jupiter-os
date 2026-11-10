# Recovery playbook

Order of operations: **stop the bleeding → recover a known-good state →
diagnose from safety**. Never debug a live production system while it is
actively broken; roll back first and reproduce the failure offline.

## 1. Live rollback

```bash
nixos-rebuild switch --rollback     # re-activate the previous generation
```

Run on the host. This is the fastest recovery for a bad activation (bad unit,
broken network config). Verify: `readlink /run/current-system` now points at
the previous generation; `systemctl --failed` is empty.

## 2. Boot-time rollback (machine won't come up usable)

1. At the boot menu choose an older generation. systemd-boot lists them
   directly; GRUB has "NixOS - All configurations".
2. Once booted and stable, either fix forward, or make the old generation
   permanent:

   ```bash
   /run/current-system/bin/switch-to-configuration boot   # as root
   ```

   This re-points the boot default at the running generation.
3. Only after recovery, delete or ignore the bad generation
   (`nixos-rebuild list-generations` to identify it). Do not garbage-collect
   good generations while recovering.

## 3. Emergency and rescue targets

From a booting-but-broken system:

- `systemctl reboot` into the boot menu and add `systemd.unit=rescue.target`
  (single-user-ish, services started) or `systemd.unit=emergency.target`
  (root shell, nothing else) at the loader.
- For a root shell without systemd conveniences, append `init=/bin/sh` and
  remount root read-write (`mount -o remount,rw /`) — a diagnostic mode, not a
  repair mode (no services, no secrets, no networking).
- Fix by switching to a known-good generation from the emergency shell:
  `nixos-rebuild switch --rollback` (may need `--option` tweaks if networking
  is down; prefer booting an older generation instead).

## 4. Repair from an installer or live media

Boot the NixOS installer ISO, then:

```bash
# find and mount the system's root (and /boot), then:
nixos-enter --root /mnt          # chroot with the target's tools and env
# inside: fix config, run nixos-rebuild switch --flake …#host
```

`nixos-enter` sets up `/proc`, `/sys`, `/dev`, and the store bind mounts. For
a machine whose root is inaccessible, a `--root` install is not the only path:
copying the closure to the mounted root plus `nixos-install` can rebuild it.

## 5. Reproduce the bad boot offline

Before attempting a fix forward, reproduce on a development machine:

```bash
nixos-rebuild build-vm --flake .#host
./result/bin/run-<host>-vm        # boot the exact generation in QEMU
```

A VM that reproduces the failure is the tight loop for boot problems. Boot
problems caused by hardware/firmware need the real console: use serial console
(`console=ttyS0`) or a physical screen and photograph the earliest visible
error; panics before the initrd rarely reach any log.

## 6. Safety rails

- Keep at least one **known-good generation** and avoid `nix-collect-garbage
  -d` on a host that is currently being repaired — the rollback target is a GC
  root, and deleting roots deletes the rescue path.
- A GC root for a closure you are testing:
  `nix-store --realise /nix/store/<closure> --add-root ./safe-root` (or
  `nix build --out-link`).
- Remote hosts with no console access: prefer `nixos-rebuild boot` (not
  `switch`) for risky changes, so a bad activation is only one reboot away
  from the previous generation, and keep SSH-capable recovery paths
  (a second management interface) intact.
- After recovery, record the root cause and add the reproduction to the test
  suite or VM checks so the same boot failure cannot return silently.

## Sources

- NixOS manual, rollback ("Troubleshooting"): https://nixos.org/manual/nixos/stable/#sec-rollback (accessed 2026-09-30)
- NixOS manual, `nixos-enter`: https://nixos.org/manual/nixos/stable/#sec-nixos-enter (accessed 2026-09-30)
- systemd emergency/rescue targets: https://www.freedesktop.org/software/systemd/man/latest/systemd.special.html (accessed 2026-09-30)
