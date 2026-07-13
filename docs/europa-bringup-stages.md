# europa Bring-Up Stages

Operational runbook for taking europa (HPE MicroServer Gen10) from its current
state — running Elementary OS, `tank` on a single vdev, second disk receiving a
file transfer — through to a fully-tuned JupiterOS NAS. Each stage lists its
precondition, the actions, how to verify it, and what it unblocks.

Config for every stage is already staged, CI-green, and committed:

- **Phase 1 config** — PR #15 (`feat/europa-nas-host`): host registration, ZFS
  NAS layer, Samba/NFS, Sanoid, Attic server, Syncthing, SMART, ARC tuning.
- **Phase 2 config** — PR #16 (`feat/europa-phase2-tuned-closure`, stacked on
  #15): `jupiter.build.microarch = "btver2"`, Cloudflare Tunnel, build-server
  module, `pallene` ISO host, substituter consumer wiring.
- **Plans** — `docs/plans/2026-07-13-001-feat-europa-phase2-tuned-closure-plan.md`
  (Phase 2; its appendix and the recovered agy `europa-plan.md` cover Phase 1).

Hardware reference (SSH-discovered 2026-07-13): AMD Opteron X3216 (1c/2t,
btver2/Puma), 8 GB ECC, Crucial MX500 500 GB SSD (OS), 2× WD 18 TB (`tank` on
sdb1; sdc is ext4 at `/mnt/sdc1` receiving the transfer). Live NIC is
`enp2s0f1` (not `enp2s0f0`). Static target `10.1.1.2/24`, gateway `10.1.1.1`.

---

## Stage 0 — File transfer (in progress, precondition for Stages 1–2)

**State:** `tank/junk` (336 GB) holds data being drained off the second disk
(`sdc`, ext4). `tank` is a single vdev on `sdb1`; `sdc` must be empty before it
can join the pool.

**Action:** None required here — wait for the transfer to finish. Monitor with
`zfs list tank/junk` (shrinks as data is reorganized) and `df /mnt/sdc1`
(empties).

**Verify:** `sdc` has no remaining data worth keeping.

**Unblocks:** Stage 1 (the physical install doesn't strictly need sdc empty,
but Stage 2 — the mirror attach — does).

---

## Stage 1 — Physical install: Phase 1 untuned NAS

**Goal:** europa boots JupiterOS, untuned from `cache.nixos.org`, with the full
NAS service stack running. This is the closure from PR #15.

**Precondition:** The OS SSD (Crucial MX500, `ata-CT500MX500SSD1_1921E206022D`)
is partitionable. Elementary OS either gets shrunk or wiped — decide before
starting.

**Actions:**
1. From a machine with the flake, build the install artifact and run
   `nixos-anywhere` (or the repo's install flow) against europa, targeting the
   OS SSD by-id path set in `hosts/europa/configuration.nix`
   (`jupiter.storage.disk`).
2. `tank` is imported at boot (`boot.zfs.extraPools = [ "tank" ]`); the
   dataset-creation oneshot provisions `tank/personal`, `tank/media`,
   `tank/backups`, `tank/services`, `tank/services/attic`, `tank/surveillance`,
   `tank/downloads`, `tank/vm`. `tank/junk` is left untouched.
3. Samba shares (`media`, `personal`, `junk` RO), NFS (`tank/media` RO, LAN),
   Sanoid snapshots, Attic server (port 8080 on `tank/services/attic`),
   Syncthing (`/tank/personal`), and SMART monitoring come up automatically.

**Verify:**
- europa is reachable at `10.1.1.2` on `enp2s0f1`.
- `zfs list` shows the new datasets alongside `tank/junk`.
- `smbclient -L //10.1.1.2` lists the shares; `showmount -e 10.1.1.2` shows NFS.
- `systemctl status atticd syncthing smartd` are active.
- ARC is capped at 5 GB: `cat /sys/module/zfs/parameters/zfs_arc_max` →
  `5368709120` (the Phase 1 plan's KTD1 — 8 GB box, not 16 GB).

**Unblocks:** Stage 3 (atticd must be running before `attic cache create`).

**Note:** europa is running *untuned* here — every binary is the portable
`cache.nixos.org` baseline. This is intentional and is exactly what Phase 2
replaces.

---

## Stage 2 — ZFS mirror completion

**Goal:** `tank` becomes a two-disk mirror so it survives a drive failure.

**Precondition:** Stage 0 complete — `sdc` is empty. **Do not start until the
transfer is verified gone**, because this wipes `sdc`.

**Actions** (from the Phase 1 plan appendix):
1. Confirm `sdc` is empty / data safely on `tank`.
2. Wipe `sdc`: `wipefs -a /dev/sdc && sgdisk -Z /dev/sdc`.
3. Partition `sdc` to match `sdb1` (or repartition both disks full-width — a
   migration-time decision; currently both are 8.2 T partial-disk).
4. Attach as mirror:
   `zpool attach tank ata-WDC_WD180EDGZ-11B2DA0_3WJ8904M-part1 ata-WDC_WD180EDGZ-11B2DA0_3WKT2RHK-part1`
5. Wait for resilver: `zpool status tank` until `state: ONLINE` / no resilver
   in progress.

**Verify:** `zpool status tank` shows a `mirror-0` vdev with two online disks.

**Unblocks:** Nothing config-side — this is pure storage redundancy. Can run
any time after Stage 0; independent of Stage 1 ordering in principle, but
easiest to reason about once europa is on JupiterOS (Stage 1).

---

## Stage 3 — Phase 2 runtime prerequisites

**Goal:** make the three runtime-only values real so the tuned closure can be
built, pushed, and trusted. None of these are knowable at config time, so they
ship as placeholders.

**Precondition:** Stage 1 complete (atticd running, reachable).

**Actions:**
1. **Cloudflare Tunnel.** In the Cloudflare dashboard, confirm the tunnel whose
   credentials are in the `cloudflare_cert` sops secret, route
   `attic.jupiter.au` → this tunnel, and copy the tunnel UUID into
   `jupiter.services.cloudflareTunnel.tunnelId` in
   `hosts/europa/configuration.nix` (currently `00000000-…`).
2. **Attic cache + public key.** On europa, create the cache and capture its
   public key:
   `attic cache create jupiter-os` → prints `jupiter-os:base64…`. Set that
   string as `jupiter.services.attic.publicKey` in
   `modules/services/attic-server.nix` (currently the `TODO-replace-…`
   placeholder).
3. **Build-server secrets.** `sops secrets/secrets.yaml` and set real values
   for `binarylane_api_token` and `attic_push_token` (currently dummy
   placeholders).
4. Rebuild europa so the real tunnel ID + public key take effect:
   `nixos-rebuild switch`.

**Verify:**
- From outside the LAN: `curl -sf https://attic.jupiter.au` responds (tunnel
  live).
- On europa: `nix show-config` shows the attic substituter with the real public
  key in `trusted-public-keys`.

**Unblocks:** Stage 4 (the build server needs the reachable tunnel + a push
token; europa needs the real public key to trust the pushed closure).

---

## Stage 4 — Build + deploy the tuned closure

**Goal:** europa switches from the untuned Phase 1 closure to the `btver2`-tuned
Phase 2 closure, substituted from its own Attic.

**Precondition:** Stage 3 complete.

**Actions:**
1. `make pallene-iso` — materializes the real tokens from sops, builds the ISO
   with them baked in, cleans up the plaintext. Output: `./result/iso/*.iso`.
2. Boot the ISO on BinaryLane: upload the ISO to a URL BinaryLane can fetch,
   create a server (≥8 vcpu / 16 GB) booted from it. Optionally set cloud-init
   user-data to a target git ref (otherwise defaults to `dashboard-v2`).
3. `pallene` runs unattended: clones the repo, builds europa's `btver2` closure,
   pushes to `attic.jupiter.au`, then self-destructs via the BinaryLane API. The
   4 h force-destroy timer is the ceiling if anything hangs.
4. On europa: `nixos-rebuild switch`. nix substitutes the tuned closure from
   `localhost:8080` (europa IS the attic server); falls through to
   `cache.nixos.org` only for anything the tuned closure shares with baseline.

**Verify:**
- `pallene` self-destructed (BinaryLane control panel shows no running server).
- On europa: `nix path-info .#nixosConfigurations.europa.config.system.build.toplevel`
  resolves from the local attic, not `cache.nixos.org`.
- europa is running the `btver2` closure — binaries are tuned; the host still
  boots and all NAS services still come up (the tuning only changed what was
  *built*, not the config shape).

**Unblocks:** europa is now the fully-tuned NAS data hub. The roadmap continues
with ganymede (resolver/services) → callisto (diskless PXE, consumes iSCSI from
europa) → himalia (laptop).

---

## Stage 5 — Deferred / future (out of the current bring-up)

These are documented in the plans but not part of getting europa tuned:

- **Legacy pool integration** — the 10 TB archive drives aren't attached; europa
  imports `tank` only. Reattach + import read-only when the hardware is
  present.
- **Moving cloudflared to ganymede** — europa runs the tunnel itself as a
  Phase 2 expedient; the long-term topology puts it on ganymede (the
  resolver/services host) once that host is registered.
- **Tuning the kiosks** — they're `skylake` on `master` but stay untuned here
  until their real CPUs are confirmed and a build-server run is justified.
- **iSCSI / replication / restic offsite** — depend on callisto and ganymede,
  neither registered yet.
