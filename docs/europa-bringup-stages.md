# europa Bring-Up Stages

> **START HERE (new session):** Stages 0, 1, 2, 3, and 4 are all **complete**.
> europa is running its full `btver2`-tuned closure at `10.1.1.2`, substituted
> from its own Attic (`attic.jupiter.au` / the `neptune.jupiter.au:8080`
> port-forward), and `tank` is a 16.4 T two-disk mirror. What's left is
> Stage 5 (deferred items) — nothing blocks anything downstream. The europa
> bring-up itself is done; the roadmap continues with ganymede.

Operational runbook for taking europa (HPE MicroServer Gen10) from bare metal
through to a fully-tuned JupiterOS NAS. Each stage lists its precondition, the
actions, how to verify it, and what it unblocks.

**Current status:**
- **Stage 0** ✅ file transfer complete; `sdc` free to mirror (Stage 2).
- **Stage 1** ✅ europa installed via nixos-anywhere; ran untuned JupiterOS at
  `10.1.1.2` before Stage 4 tuned it. ZFS (`rpool` + `tank`, 1.97 TB
  preserved), Samba, NFS, atticd, syncthing, smartd, ARC capped at 5 GB.
  `amd_iommu=off` set so the Marvell 88SE9230 data drives enumerate. cmatrix
  screensaver on tty1.
- **Stage 2** ✅ done (2026-07-20) — tank is now a 16.4T whole-disk mirror.
  See [Stage 2](#stage-2--zfs-mirror-completion--done) for the actual procedure.
- **Stage 3** ✅ all runtime prerequisites real and committed (see below).
- **Stage 4** ✅ **done** — europa is running its full `btver2`-tuned closure,
  substituted from its own Attic. See `docs/europa-stage4-progress.md` for the
  run history.
- **Stage 5** deferred.

Config for every stage is already staged, CI-green, and committed:

- **Phase 1 config** — PR #15 (`feat/europa-nas-host`): host registration, ZFS
  NAS layer, Samba/NFS, Sanoid, Attic server, Syncthing, SMART, ARC tuning,
  `amd_iommu=off`, DNS nameservers, cmatrix screensaver.
- **Phase 2 config** — PR #16 (`feat/europa-phase2-tuned-closure`, stacked on
  #15): `jupiter.build.microarch = "btver2"`, Cloudflare Tunnel, build-server
  module, `pallene` ISO host, substituter consumer wiring, real attic public key.
- **Plans** — `docs/plans/2026-07-13-001-feat-europa-phase2-tuned-closure-plan.md`
  (Phase 2; its appendix and the recovered agy `europa-plan.md` cover Phase 1).

Hardware reference (SSH-discovered 2026-07-13): AMD Opteron X3216 (1c/2t,
btver2/Puma), 8 GB ECC, Crucial MX500 500 GB SSD (OS), 2× WD 18 TB (`tank` on
`sdb1`; `sdc` now free). Live NIC is `enp2s0f1` (not `enp2s0f0`). Static
`10.1.1.2/24`, gateway `10.1.1.1`.

---

## Stage 0 — File transfer ✅ DONE

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

## Stage 1 — Physical install: Phase 1 untuned NAS ✅ DONE

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

## Stage 2 — ZFS mirror completion ✅ DONE (2026-07-20)

**Goal:** `tank` becomes a two-disk mirror so it survives a drive failure.

**Precondition:** Stage 0 complete — `sdc` is empty. **Do not start until the
transfer is verified gone**, because this wipes `sdc`.

**Decision:** whole-disk vdevs, not hand-managed partitions. ZFS holds the
disks by-id with no `-partN` suffix, owns the GPT layout (creates a full-width
`part1` + 8 MB `part9` Solaris reserved internally), and can rebuild that
layout automatically on `zpool replace`. The original pool was hand-created on
`sda1` at 8.2 T with `sda2` (8.2 T) wasted, so the migration also doubled the
pool's logical capacity (8.17 T → 16.4 T) by giving ZFS the full width of both
disks.

**Actions actually taken** (attach-then-grow — keeps the pool redundant
throughout except for the brief wipe-and-reattach of sda in Phase 2):
0. `zpool set autoexpand=on tank` — needed so the pool grows when both
   mirror members are full-width.
1. **Phase 1 — add sdc as whole-disk mirror of the legacy sda1 partition:**
   - `nix-shell -p gptfdisk --run 'sgdisk -Z /dev/sdc'` (wipe sdc; ext4
     signatures and stale GPT gone).
   - `zpool attach tank ata-WDC_WD180EDGZ-11B2DA0_3WJ8904M-part1 ata-WDC_WD180EDGZ-11B2DA0_3WKT2RHK`
     (ZFS auto-partitions sdc with a full-width `sdc1` + `sdc9` and adds it as
     a mirror member; vdev appears without `-partN` suffix since ZFS owns the
     disk).
   - Wait for resilver — 2.00 T at ~145 MB/s, took 4h11m, 0 errors.
2. **Phase 2 — replace the legacy sda1 partition with a whole-disk sda vdev:**
   - `zpool detach tank ata-WDC_WD180EDGZ-11B2DA0_3WJ8904M-part1` (pool runs
     on sdc alone — brief degraded window).
   - `nix-shell -p gptfdisk --run 'sgdisk -Z /dev/sda'` (kills both sda1 and
     the wasted sda2 in one wipe).
   - `zpool attach tank ata-WDC_WD180EDGZ-11B2DA0_3WKT2RHK ata-WDC_WD180EDGZ-11B2DA0_3WJ8904M`
     (ZFS auto-partitions sda to match sdc).
   - Wait for resilver — 2.00 T, took 5h01m, 0 errors. Pool autoexpanded from
     8.17 T to 16.4 T once both members were full-width and the second
     resilver completed.

**Verify:** `zpool status tank` shows `mirror-0` with both `ata-WDC_WD180EDGZ-…`
members ONLINE, no `-partN` suffix on either vdev; `zpool list -v tank` shows
both members at 16.4 T and the pool at 16.4 T total. Confirmed 2026-07-20.

**Unblocked:** nothing config-side — pure storage redundancy. The pool now
survives any single disk failure; `zpool replace` on either member will work
against a fresh bare disk with no manual partitioning step.

**Notes for next time:**
- The pool features were `zpool upgrade`d to full OpenZFS 2.4.3 in the same
  window (accidentally — `zpool upgrade tank` is not a read-only status check,
  it performs the upgrade). New features enabled include `block_cloning`,
  `zstd_compress`, `fast_dedup`, `raidz_expansion`, `device_rebuild` (the last
  gives accurate resilver progress). Pool is now incompatible with older ZFS
  versions — irrelevant on this single-host fleet.
- `autoexpand=on` is a permanent pool property; future member swaps that
  increase capacity will grow the pool automatically.

---

## Stage 3 — Phase 2 runtime prerequisites ✅ DONE

**Goal:** make the three runtime-only values real so the tuned closure can be
built, pushed, and trusted. None of these are knowable at config time, so they
shipped as placeholders — **all now filled** (commits `dae0b15`, `5bd9872`, and
the attic-public-key commit on `feat/europa-phase2-tuned-closure`).

**Precondition:** Stage 1 complete (atticd running, reachable). ✅

**Status of each piece:**
1. **Cloudflare Tunnel** ✅ — `jupiter.services.cloudflareTunnel.tunnelId` in
   `hosts/europa/configuration.nix` is the real UUID
   `aa1088b8-a0e1-4073-8567-6a9bf5fb4bd7`. Tunnel credentials are in the
   `cloudflare_cert` sops secret; `attic.jupiter.au` is routed to it.
2. **Attic cache + public key** ✅ — cache `jupiter-os` created on europa's
   atticd via `atticadm make-token` + `attic cache create`. Public key
   `jupiter-os:jd6naJxSxt9xPtYTaOSQDOoeoHil5OsVy8ltpIBs9dQ=` is set as
   `jupiter.services.attic.publicKey` in `modules/services/attic-server.nix`.
3. **R2 bucket for the pallene ISO** ✅ — `cloudflare_account_id`,
   `r2_access_key_id`, `r2_secret_access_key` are all real in sops. The bucket
   `jupiter-os-pallene-iso` is referenced by `scripts/upload-pallene-iso-r2.sh`.
4. **Build-server secrets** ✅ — `binarylane_api_token` and `attic_push_token`
   are real in sops.
5. Rebuild so the real tunnel ID + public key take effect: still pending — run
   `nixos-rebuild switch --flake .#europa --target-host root@10.1.1.2
   --build-host root@10.1.1.2` **as the first step of Stage 4** (it also brings
   the Phase 2 config — microarch, tunnel, substituter — live on europa).

**Verify (optional, before Stage 4):**
- From outside the LAN: `curl -sf https://attic.jupiter.au` responds (tunnel
  live).
- On europa: `nix show-config` shows the attic substituter with the real public
  key in `trusted-public-keys`.

**Unblocks:** Stage 4 (the build server needs the reachable tunnel + a push
token; europa needs the real public key to trust the pushed closure).

---

## Stage 4 — Build + deploy the tuned closure ✅ DONE

**Goal:** europa switches from the untuned Phase 1 closure to the `btver2`-tuned
Phase 2 closure, substituted from its own Attic.

**Result:** done — europa is running the `btver2`-tuned closure, substituted
from its own Attic. See `docs/europa-stage4-progress.md` for the run history
(BinaryLane capacity stockouts, the R2 presign SigV2/SigV4 bug, the
nix-command/hostname build-server fixes). The actions below are the reusable
procedure — follow them again for any future rebuild of europa's tuned
closure (e.g. after a nixpkgs bump).

**Actions:**
0. **Bring the Phase 2 config live on europa** (tunnel, substituter, real
   public key, microarch flag — config-only, no tuned binaries yet; everything
   still substitutes from `cache.nixos.org`):
   ```bash
   nix run nixpkgs#nixos-rebuild -- switch --flake .#europa \
     --target-host root@10.1.1.2 --build-host root@10.1.1.2
   ```
   This also wires europa to *consume* from `localhost:8080` — until a tuned
   closure is pushed there, nix simply falls through to `cache.nixos.org`
   (harmless).
1. **`make rebuild-world`** — one command runs the whole cycle: builds the
   pallene ISO (`make pallene-iso`, baking in the real tokens), uploads it to
   the R2 bucket (`scripts/upload-pallene-iso-r2.sh`, presigning a 4 h URL),
   then drives BinaryLane (`scripts/binarylane-build-server.sh`: create a
   placeholder server → upload the ISO as a backup image from the presigned
   URL → attach as boot media → reboot → wait for self-destruct). Override
   the build target git ref with `GIT_REF=<ref>` (defaults to `main`).
2. **`pallene` runs unattended** once booted: clones the repo, builds europa's
   `btver2` closure, pushes to `attic.jupiter.au`, then self-destructs via
   the BinaryLane API. The 4 h force-destroy timer is the ceiling.
3. **On europa, switch to the tuned closure:**
   ```bash
   nix run nixpkgs#nixos-rebuild -- switch --flake .#europa \
     --target-host root@10.1.1.2 --build-host root@10.1.1.2
   ```
   nix substitutes the tuned closure from `localhost:8080` (europa IS the attic
   server); falls through to `cache.nixos.org` only for anything the tuned
   closure shares with baseline.

**Push-path gotchas (learned 2026-07-17, mid-Stage-4):**
- The Cloudflare Tunnel 524s on any NAR that takes >100 s to upload, which is
  why pallene pushes over the UniFi WireGuard mesh (`http://10.1.1.2:8080`).
- The mesh itself can degrade: ICMP passes both ways but europa→pallene TCP
  payloads get dropped (established connections wedge with data stuck in
  Send-Q, new connects time out). If pushes stall while `ping` looks healthy,
  suspect this — don't debug atticd first.
- Reliable fallback that bypasses both: a reverse SSH tunnel from europa to
  pallene's public IP (`ssh -N -R 127.0.0.1:18080:127.0.0.1:8080
  root@<pallene>`), then point `/root/.config/attic/config.toml` on pallene at
  `http://127.0.0.1:18080`. Plain outbound TCP, no Cloudflare timeout, no WG.
- atticd can wedge silently under upload storms (SQLite pool exhaustion; the
  service stays "active" while serving nothing). The `atticd-watchdog` timer
  in `modules/services/attic-server.nix` restarts it automatically once the
  Phase 2 closure is live; until then it runs as a transient
  `atticd-watchdog-tmp` unit on europa.

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
- **Tuning the kiosks** — they're `skylake` on `archive/full-fleet-reference`
  but stay untuned here until their real CPUs are confirmed and a build-server
  run is justified. (Callisto's i5-8500T is also Coffee Lake → `skylake` for
  GCC purposes; `jupiter.build.microarch = "skylake"` is committed on
  callisto as a roadmap entry only — pallene must build and push the
  skylake-tagged closure to attic before callisto's next deploy. Once that
  closure exists in attic, the same `skylake`-tagged bootstrap paths can be
  reused by any future tuned kiosk without a separate bootstrap rebuild.)
- **callisto's own skylake closure** — `jupiter.build.microarch = "skylake"`
  is set in `hosts/callisto/configuration.nix` and callisto is listed in
  pallene's `hosts` / `microarchs`, but the closure has NOT been built yet.
  The next `make rebuild-world` run will build it alongside europa's btver2
  closure. Until then, callisto must NOT be `nixos-rebuild switch`ed against
  HEAD from itself — diskless + tmpfs /nix/store means a from-scratch
  skylake bootstrap would OOM the box.
- **iSCSI / replication / restic offsite** — depend on ganymede (not
  registered yet); callisto's role is now the shared Nix builder, not the
  old design's diskless database host.
- **Fleet-wide LTO** (`-flto` via a stdenv-level overlay, not `-O3`/`-Ofast` —
  the latter risks real correctness bugs via `-ffast-math`-style semantic
  changes, not just instability) — genuine additional tuning headroom on top
  of `jupiter.build.microarch`, but touches the same global mechanism, so it
  invalidates the *entire* closure's hashes and forces a full rebuild from
  bootstrap again, same as microarch tuning did. Also has a real chance some
  packages fail to build cleanly under forced LTO (well short of every
  package in a full closure handles it), needing per-package exceptions the
  same way `bmake`'s flaky check needed one. Deliberately sequenced after —
  don't stack it onto an unproven pipeline: get one clean, complete pallene
  run finishing end-to-end on the current fixes first, so a failure under
  LTO isn't ambiguous between "the build mechanism" and "the new flag."
