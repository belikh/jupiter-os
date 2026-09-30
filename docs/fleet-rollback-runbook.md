# Fleet rollback runbook

Recover first, diagnose second. A host that lost SSH, networking, or boot
needs a generation change before anyone reasons about root causes.

## 1. Live rollback (host reachable)

```bash
ssh root@<host> 'nixos-rebuild switch --rollback'
```

Re-activates the previous generation. Verify by observation, never by exit
code: `readlink /run/current-system`, `systemctl --failed`, and the unit you
were fixing (`systemctl status <unit>`).

## 2. Boot-time rollback (host unusable)

1. At the boot menu pick the previous generation: systemd-boot lists entries;
   GRUB has "NixOS - All Configurations".
2. Once up, make it permanent:
   `/run/current-system/bin/switch-to-configuration boot` (as root).
3. Do **not** garbage-collect while recovering — `nix-collect-garbage -d`
   deletes the running and previous generations (the rollback targets).

## 3. Console-less hosts

- **callisto** boots via PXE from europa and pins `init=` to a callisto
  toplevel. After any switch or rollback on callisto, republish the PXE assets
  so the pinned `init` exists in its store; publishing runs after the switch by
  design (`jupiter-pxe-assets.service`). If callisto is unreachable over SSH,
  PXE is its console.
- **kiosks** have physical screens/keyboards; **europa** has the console;
  **pallene** has the VPS serial/VNC console.

## 4. Generation inventory and retention policy

- `nixos-rebuild list-generations` — dates, kernels, current marker.
- Fleet policy (nixos-review F-10): `systemd-boot.configurationLimit = 20`
  (1G ESP fits ~7 MB/generation), GRUB limit 20 on pallene, weekly
  `nix-collect-garbage --delete-older-than 30d` — entries and generations
  expire together.
- CI pins the last three main builds per host as GC roots in Harmonia
  (`scripts/ci/retain-recent.sh`); those are network rollback targets for
  re-deploys, not local boot entries.

## 5. After the rollback

- Confirm the running closure equals the intended generation
  (`readlink /run/current-system`), the system reaches `running`
  (`systemctl is-system-running`), and `systemctl --failed` is empty.
- Record the failure and the reproduction before fixing forward; a rollback is
  a pause, not a resolution.

## 6. If no generation remains

Rebuild from a known-good revision of the flake:

```bash
ssh root@<host> 'nixos-rebuild switch --flake github:belikh/jupiter-os/<rev>#<host>'
```

or reinstall (see the disaster-recovery runbook — nixos-review F-12, planned).
