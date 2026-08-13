# callisto iSCSI-Root Provisioning

**Status: done and verified.** callisto boots persistently over iSCSI from
europa. See `hosts/callisto/configuration.nix` and
`modules/services/iscsi-target.nix` for the config this describes.

**Design: ext4 over iSCSI, not ZFS.** An earlier draft of this doc staged a
ZFS-over-iSCSI plan (temp-pool-then-rename via a rescue netboot, mirroring
how europa itself avoids an `rpool` name collision). **That design is wrong
and was abandoned before completion** — ZFS on a network block device
deadlocks the boot (the ZFS import path and the network stack bringing up
the iSCSI session end up depending on each other). Do not resurrect it. ext4
has no pool-name concept, so the entire rename dance that made the ZFS plan
complicated is unnecessary here.

**Why iSCSI root at all:** the previous design kept callisto fully diskless
(`copytoram`, no persistent state) after an earlier NFS-backed `/persist`
attempt burned a session on initrd fragility. iSCSI root gives callisto a
real persistent root — closing the "sops can't decrypt at runtime here" gap
for free, since secrets now decrypt at activation like on any other host —
while still booting entirely over PXE with no local disk.

## Design

- **Backing store:** europa zvol `tank/services/callisto-root` (200G, `zfs
  create -V`), created idempotently by `modules/services/iscsi-target.nix`'s
  `zfs-create-iscsi-zvol.service`, sized for a Nix store + system root, not
  data.
- **Target:** europa runs the kernel's LIO target (`services.target`, via
  `modules/services/iscsi-target.nix`), IQN
  `iqn.2026-07.au.jupiter:europa:callisto-root`, portal `10.1.1.2:3260`, one
  LUN, one by-IQN ACL for `iqn.2026-07.au.jupiter:callisto`. No CHAP — access
  control is by-IQN only, matching the LAN-only trust model
  `modules/storage/nas-nfs.nix` already uses for other host-scoped exports.
- **Initiator:** callisto's initrd logs into the target and mounts
  `/dev/disk/by-path/ip-10.1.1.2:3260-iscsi-iqn.2026-07.au.jupiter:europa:callisto-root-lun-0`
  as ext4 `/`, whole-device (no partition table) — see `fileSystems."/"` in
  `hosts/callisto/configuration.nix`.
- **Boot chain unchanged:** europa still PXE-serves `ipxe.efi`+`bzImage`+
  `initrd` to callisto exactly as the old RAM-resident design did; the only
  change is what the initrd does next (iSCSI login + ext4 root mount instead
  of unpacking a RAM squashfs).
- **Served from two roots (see "Publishing the netboot assets" below):** the
  TFTP root in europa's closure carries only `ipxe.efi`/`undionly.kpxe`; the
  callisto-derived `boot.ipxe`/`bzImage`/`initrd` are published separately.

## Publishing the netboot assets

europa's system closure must not reference callisto's, or building/evaluating
europa also builds callisto's whole skylake-tuned closure (which is what
`nix build .#nixosConfigurations.europa...` used to do). So the netboot chain
is split:

| Artifact | Contents | Where it lives | Served over |
|---|---|---|---|
| `.#pxe-tftproot` | `ipxe.efi`, `undionly.kpxe` | europa's system closure (`jupiter.pxe.root`) | TFTP (:69) |
| `.#pxe-netboot-assets` | `boot.ipxe`, `bzImage`, `initrd` | `/var/lib/pxe-netboot/current` — a symlink, not a closure reference | HTTP (:8082) |

iPXE's embedded script is a static chainload to
`http://10.1.1.2:8082/boot.ipxe`, so everything callisto-specific is fetched
at runtime from the mutable half.

**Publish (on europa, as root):**

```bash
systemctl start jupiter-pxe-assets.service   # nix build --out-link /var/lib/pxe-netboot/current
```

**Order matters.** `boot.ipxe` pins `init=<callisto-toplevel>/init`, and
stage-1 `switch_root`s into that path *on callisto's own iSCSI root* — so the
generation being served has to already exist there:

1. commit + push to `main`
2. `nixos-rebuild switch` **on callisto** (writes the new toplevel to its root)
3. `systemctl start jupiter-pxe-assets.service` **on europa**

The unit is one-shot with no timer on purpose: an automatic pull of `main`
would race ahead of step 2 and serve a path callisto doesn't have. A failed
run leaves the previous `current` symlink (and its indirect GC root)
untouched, so callisto keeps netbooting the last-published generation.

**First-time bootstrap (the one ordering trap).** nginx serves `current`, so
between switching europa to the split config and the first publish there is a
window where the HTTP half 404s and callisto cannot netboot. Close it by
publishing *before* switching europa — the unit doesn't exist yet, but its
command does, and it also GC-roots the kernel/initrd that europa's outgoing
closure was pinning:

```bash
mkdir -p /var/lib/pxe-netboot
nix build github:belikh/jupiter-os#pxe-netboot-assets \
  --out-link /var/lib/pxe-netboot/current
nixos-rebuild switch --flake github:belikh/jupiter-os#europa
```

The service can only ever succeed when the paths are already substitutable —
they're `gccarch-skylake`-tagged and europa doesn't advertise that feature, so
it substitutes from its own store (CI pushes callisto's closure there) or
delegates to callisto; it never compiles a kernel on the NAS.

## Provisioning (what actually happened, for the next time this is needed)

1. Stand up europa's target (`nixos-rebuild switch` on europa creates the
   zvol and starts `iscsi-target.service`).
2. Format the *empty* LUN as ext4 from europa (or any host with `open-iscsi`
   and iSCSI access to the portal) — no `nixos-install`/disko step needed,
   since ext4 root doesn't need a pre-populated closure the way the old ZFS
   plan's chicken-and-egg boot problem required. callisto's own PXE-served
   initrd installs itself via normal activation once it boots against the
   formatted-but-empty LUN.
3. Point callisto's config at the LUN (`fileSystems."/"`, see
   `hosts/callisto/configuration.nix`) and deploy the PXE closure.
4. Power-cycle callisto (AMT — `scripts/amt.py on`/`off`/`cycle`, see memory
   on AMT/KVM tooling — or physically).

## Verify (this is the real acceptance test — run both halves)

A live iSCSI session surviving on its own proves little; the config baked
into `iscsi-target.service`'s systemd unit only gets exercised on a genuine
cold boot. Confirm **both**:

- **europa, cold boot:** `systemctl status iscsi-target` shows `active
  (exited)`/`code=exited, status=0/SUCCESS`, and `targetcli ls` shows the
  backstore, target, ACL, LUN, and portal all restored from
  `/etc/target/saveconfig.json`.
- **callisto, cold PXE+iSCSI boot:** `hostname` returns `callisto`, `mount |
  grep ' / '` shows `/dev/sda on / type ext4`, `iscsiadm -m session` shows
  the session up, and a build dispatched to callisto from another host
  succeeds (`jupiter.core.buildMachines`).

**If it hangs:** serial console (SOL) on this box is known-unreliable (see
`hosts/callisto/configuration.nix`'s git history, 2026-07-23 revert) — don't
count on it for visibility. Recovery is a power-cycle back to whatever PXE
currently serves.

## Known gotcha: `nixos-rebuild switch` vs `boot` near `iscsi-target`

If europa's nix store db is ever in a degraded state near
`iscsi-target.service`'s dependencies (e.g. after manual store surgery),
prefer `nixos-rebuild boot` over `switch` when fixing it. `switch` restarts
changed units immediately — and `iscsi-target.service`'s `ExecStop` is
`targetctl clear`, which tears down the *live* kernel LIO config backing
callisto's mounted root. `boot` builds and sets the new generation as
default without touching the running system, so the fix takes effect on the
next (deliberate, verified) reboot instead of live-testing it against a
mounted disk.
