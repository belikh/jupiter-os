# europa eXo-game datasets — case-sensitive → case-insensitive migration

> **Status: PLANNED, NOT YET EXECUTED.** This runbook documents a verified
> procedure (the technique was tested empirically on europa) for converting
> the three curated eXo-game ZFS datasets from `casesensitivity=sensitive`
> to `casesensitivity=insensitive`. Once all three are insensitive, a whole
> class of case-mismatch workarounds in this repo can be retired (see
> [Post-migration code cleanup](#post-migration-code-cleanup)).

europa (HPE MicroServer Gen10, `10.1.1.2`) hosts the curated retro-game
collections the TCx Wave kiosks run over NFS. These collections were authored
on Windows (a case-insensitive filesystem); their LaunchBox XMLs and per-game
emulator configs routinely get on-disk casing *wrong* (e.g. eXoWin3x's XML
says `eXoWin3X` for 1062 of 1139 games; eXoWin9x's 86Box `Play.cfg` says
`winquake.cue` where the zip extracts `Winquake.cue`). Today the datasets are
`casesensitivity=sensitive`, so the launch stack carries a thicket of
case-resolution workarounds to bridge Windows-authored paths to the real
on-disk names. Making the datasets case-insensitive makes the filesystem do
that bridging for free, the way Windows did when eXo authored the data.

---

## Scope

Three datasets, all currently `casesensitivity=sensitive` (inherited from
`tank`), under a common parent:

| Dataset | Size | Mountpoint (inherited) |
| --- | --- | --- |
| `tank/archive/retro/games/curated/exo-dos` | 641 GB | `/tank/archive/retro/games/curated/exo-dos` |
| `tank/archive/retro/games/curated/exo-win3x` | 351 GB | `/tank/archive/retro/games/curated/exo-win3x` |
| `tank/archive/retro/games/curated/exo-win9x` | 278 GB | `/tank/archive/retro/games/curated/exo-win9x` |

**Total ≈ 1.24 TB.** Parent `tank/archive/retro/games/curated` has its
`mountpoint` set **locally** to `/tank/archive/retro/games/curated`; the
children **inherit** it, so each child mounts at `<parent
mountpoint>/<child-name>` (ZFS appends the dataset components below the one
with the explicit `mountpoint`). This is load-bearing for the procedure: a
child dataset keeps the *same path* as long as it keeps the *same name*.

The datasets have `sharenfs=off` set on themselves — **NFS export is
configured elsewhere**, not per-dataset. The kiosks mount
`${nfsHost}:${curatedNfsPath}/<name>` (see `modules/desktop/exodos.nix`,
`nfsHost=10.1.1.2`, `curatedNfsPath=/tank/archive/retro/games/curated`), so
the export is keyed on the path. Because the procedure keeps the identical
path, **no NFS re-export and no kiosk repoint is needed**.

The kiosks mount each collection read-only over NFS as the **lower** of an
overlayfs (upper at `/var/lib/exo-overlay/<name>/upper`, persisted). The
recreated dataset keeps the identical lower path, so the overlay lowers are
unchanged and the persisted uppers (game saves, first-run extractions)
survive — they reference lower paths, which don't move.

---

## Why the obvious tools DON'T work

`casesensitivity` is a **create-time-only** property. All of the following
were proven to fail on europa — do not waste a maintenance window on them:

- `zfs set casesensitivity=insensitive <ds>` → **fails**: `casesensitivity`
  is readonly.
- `zfs send <sensitive>@snap | zfs receive <newname>` → received dataset is
  still **sensitive** (the flag rides in the objset).
- `zfs receive -o casesensitivity=insensitive` → **fails**: `invalid property
  'casesensitivity'`.
- `zfs receive -x casesensitivity` → **fails**: `invalid property
  'casesensitivity'`.
- Pre-creating an insensitive destination and `zfs receive -F` into it → the
  full receive **overwrites** the destination's objset, flipping it back to
  **sensitive**.

**Conclusion: `zfs send | zfs receive` is the wrong tool.** It cannot change
`casesensitivity` because the property is baked into the objset that the
stream carries.

---

## The only working technique

A plain **file copy** into a freshly-created insensitive dataset, with the
old dataset renamed aside first so the recreate reuses the identical
path/mountpoint/NFS export:

```
per dataset:
  zfs rename  <ds>  <ds>.cs                     # old data moves to <ds>.cs/ (auto-mounted)
  zfs create -o casesensitivity=insensitive <ds> # inherits the SAME mountpoint -> <ds>/
  cp -aT <ds>.cs_mount/  <ds>_mount/             # filesystem-level copy folds case on the target
  # ... verify (below), THEN ...
  zfs destroy <ds>.cs
```

Verified on europa: a freshly-created insensitive dataset plus a `cp` does
fold case — a file stored as `Foo.TXT` is found via `ls foo.txt` on the new
dataset. `-a` preserves perms/owners/times/xattrs and copies recursively;
`-T` (no-target-directory) with a trailing slash on the source copies the
*contents* of the source into the destination.

```
                ┌─────────────────────────────────────────────────────────┐
   SENSITIVE    │ zfs rename exo-win9x  exo-win9x.cs                       │
   (old data)   │   old data now mounted at .../exo-win9x.cs/              │
                │   .../exo-win9x/ path is now FREE                        │
                └─────────────────────────────────────────────────────────┘
                                       │
                                       ▼
                ┌─────────────────────────────────────────────────────────┐
   INSENSITIVE  │ zfs create -o casesensitivity=insensitive exo-win9x      │
   (empty)      │   inherits parent mountpoint -> .../exo-win9x/ (SAME)    │
                └─────────────────────────────────────────────────────────┘
                                       │
                                       ▼
                ┌─────────────────────────────────────────────────────────┐
   copy         │ cp -aT .../exo-win9x.cs/  .../exo-win9x/                 │
                │   ~30 min at HDD speed (exo-dos 641G ≈ 75 min)          │
                └─────────────────────────────────────────────────────────┘
                                       │
                                       ▼
                  verify wrong-case lookup  ── ok? ──▶ zfs destroy .cs
                                              │
                                              └── fail? rollback (rename back)
```

---

## Pre-flight (run BEFORE every migration)

### 1. Scan for case collisions

On a case-insensitive filesystem, two sibling entries that differ only by
case (e.g. `Foo.txt` and `foo.txt` in the same directory) **cannot coexist**
— the `cp` would silently overwrite one with the other. This is near-impossible
for these collections (they were authored on Windows, which forbids such
pairs), but **every dataset must be scanned before its copy step**.

Run the scanner in this repo against each dataset root, **as root, on
europa** (so the scan reads local ZFS, not the kiosks' NFS view):

```bash
cd /path/to/jupiter-os
./scripts/zfs-case-collision-scan.sh \
  /tank/archive/retro/games/curated/exo-dos \
  /tank/archive/retro/games/curated/exo-win3x \
  /tank/archive/retro/games/curated/exo-win9x
```

- Exit **0** = no collisions → safe to proceed with that dataset.
- Exit **1** = collisions found → the groups are printed to stdout with
  absolute paths. **Resolve every collision first** (rename one side), then
  re-scan until clean. **Do not migrate a dataset that still reports
  collisions.**

### 2. Snapshot (cheap insurance)

Take a recursive snapshot of the parent so there is a known-good rollback
point that costs nothing until you destroy it:

```bash
zfs snapshot -r tank/archive/retro/games/curated@pre-ci-migration
```

This is belt-and-braces on top of the `.cs` rename rollback below.

---

## Per-dataset procedure

> **Schedule one maintenance window per dataset.** The three datasets are
> independent — migrate **one at a time**, confirm it, then move on. Do not
> run two copies concurrently (they share the same HDD pool and would thrash).

Run as root on europa. The example below is `exo-win9x`; substitute the
dataset and mount path for the others. Let `DS=tank/archive/retro/games/curated/exo-win9x`
and `MNT=/tank/archive/retro/games/curated/exo-win9x`.

### Step 0 — confirm pre-flight is clean

```bash
./scripts/zfs-case-collision-scan.sh "$MNT"        # must exit 0
zfs get -H -o value casesensitivity "$DS"          # expect: sensitive
```

### Step 1 — rename the sensitive dataset aside

`zfs rename` relocates the dataset and re-mounts it at the `.cs` path
(inherited mountpoint + new name component), freeing the original path:

```bash
zfs rename "$DS" "$DS.cs"
zfs list -r tank/archive/retro/games/curated       # confirm $DS gone, $DS.cs present
ls -ld "$MNT.cs"                                    # old data lives here now
```

### Step 2 — create the insensitive replacement

It inherits the parent's `mountpoint`, so it mounts at the **identical** path:

```bash
zfs create -o casesensitivity=insensitive "$DS"
zfs get -H -o value casesensitivity "$DS"          # MUST show: insensitive
zfs get -H -o value mountpoint "$DS"               # inherited -> same path
```

### Step 3 — copy the data (the maintenance window)

This is the step the kiosk arcade is unavailable for that collection — see
[Live-fleet impact](#live-fleet-impact).

```bash
cp -aT "$MNT.cs/" "$MNT/"
```

Timing at HDD speed: ~30 min for a 278–351 GB dataset; **exo-dos (641 GB)
≈ 75 min**.

### Step 4 — verify before destroying the source

Do **both** sanity checks. Only destroy `.cs` once both pass.

```bash
# (a) File count and used space agree (allow rounding on used).
echo "src files:" ; find "$MNT.cs" -type f | wc -l
echo "dst files:" ; find "$MNT"     -type f | wc -l

# (b) The actual point of the exercise: a WRONG-case lookup now resolves.
# Pick a known mixed-case path that exists under .cs and confirm the
# lowercased lookup hits on the new dataset, e.g. for exo-win9x's 86Box ROMs:
ls "$MNT/eXo/emulators/86Box98/roms"               # see the mixed-case names
ls "$MNT/eXo/emulators/86Box98/roms/<lowercase-rom-filename>"   # wrong case -> still found
```

The wrong-case lookup succeeding is the proof the new dataset is
case-insensitive. If it fails (returns "No such file"), **stop** — the copy
target is still sensitive somehow; do not destroy `.cs`; rollback instead.

### Step 5 — destroy the old sensitive dataset

```bash
zfs destroy "$DS.cs"
```

Only after this is the migration of that dataset irreversible. Before this
point, rollback is trivial.

### Step 6 — confirm the kiosks

The NFS export path is unchanged, so no re-export or kiosk repoint is needed.
On a kiosk, confirm the collection's overlay still sees the data (the
automounted NFS lower is lazy — a read will trigger it):

```bash
ls /mnt/europa-games/exo-win9x | head              # lower still resolves at same path
```

Optionally launch one game from the collection to confirm the full
overlayfs + emulator path still works end-to-end (and, as a bonus, that a
previously case-broken title now launches without the workarounds).

---

## Rollback

**Until `zfs destroy "$DS.cs"` runs, rollback is a two-command rename back.**
Use this any time Step 4 verification fails, or anything else looks wrong
before destroy:

```bash
zfs destroy "$DS"            # remove the (empty or partial) insensitive dataset
zfs rename "$DS.cs" "$DS"    # old sensitive data returns to the original path/mountpoint
```

The data was never touched (the copy was one-way into the new dataset), so
this is lossless. If you took the pre-flight snapshot
(`@pre-ci-migration`), you additionally have `zfs rollback` as a further
fallback.

---

## Live-fleet impact

**europa is serving amalthea's running arcade over NFS right now.** During a
given dataset's rename → create → copy window (Step 1 through Step 3), that
collection's path is either absent or only partially populated, so it is
**unavailable/inconsistent to the kiosks** for the duration of the copy.

Mitigations:

- **Migrate one dataset at a time.** Only one of {exo-dos, exo-win3x,
  exo-win9x} is disrupted at any time; the other two keep serving normally.
- **Pick a maintenance window** when the affected collection isn't in active
  use (e.g. migrate exo-win9x while someone is playing a DOS title).
- Worst case a kiosk hits a half-copied collection: the overlay lower
  (read-only NFS) simply returns missing files until the copy completes; no
  kiosk-side state is corrupted (saves/extractions live in the persisted
  upper, which references the unchanged lower paths).
- The persisted overlay uppers survive every migration — they reference
  lower paths that do not change.

---

## Post-migration code cleanup

These case-mismatch workarounds become **retirable** once ALL THREE datasets
are confirmed insensitive and live fleet-wide (verify on europa first, then
on at least one kiosk per collection). They must NOT be removed before the
migration is confirmed — until then they are the only thing keeping the
case-sensitive datasets launchable. List only; do not implement as part of
the migration.

### `scripts/exo-to-pegasus.py` — metadata generator
- **`CasePathResolver`** class (`scripts/exo-to-pegasus.py:107`) and its
  single use site: instantiated at `:306` (`resolver = CasePathResolver(root)`),
  used to fix per-game conf paths at `:328`–`:334` and manual paths at `:358`.
  On a case-insensitive root, `os.path.isfile()` matches regardless of case,
  so the resolver's `resolve()` and the `case_fixed` counter (`:303`, `:334`,
  summary at `:486`) become dead code.
- **The `--rewrite` / `rewrites` mechanism**: the argparse option
  (`scripts/exo-to-pegasus.py:412`), its parsing/validation in `main`
  (`:450`–`:452`), and the substring-replace loop in
  `game_dir_from_application_path` (`:154`–`:155`). Retire together with the
  only caller-side rewrite — `eXoWin3X:eXoWin3x` — passed from the module
  (`modules/desktop/exodos.nix:60`, `collections.exo-win3x.rewrites`, threaded
  through the generator command at `modules/desktop/exodos.nix:238`). On a
  case-insensitive root the on-disk casing disagreement no longer matters.

### `scripts/exo-launch.sh` — per-game launcher
- **`ci_resolve()`** — the single-level case-insensitive name resolver
  (`scripts/exo-launch.sh:40`), used to reconcile a game dir / zip name whose
  case differs between the conf and the extracted files (e.g. `hugo3Jd` →
  `hugo3jd`) at `:149` and `:177`.
- **`ci_resolve_path()`** — the multi-level relative-path case resolver
  (`scripts/exo-launch.sh:52`), plus the **86Box `Play.cfg` case-reconciliation
  loop** in the `86box` branch that calls it (the `while IFS= read` rewrite at
  `scripts/exo-launch.sh:343`–`:360`, branch entry `:324`). That loop rewrites
  every `hdd_*_fn=` / `cdrom_*_image_path=` line in the staged per-game cfg to
  on-disk casing; with an insensitive underlying dataset, 86Box's
  case-sensitive opens will match directly and the whole rewrite pass is a
  no-op.

Removing these shrinks both scripts materially and deletes the `--rewrite`
plumbing end-to-end (option → parser → `game_dir_from_application_path` →
module `rewrites` field → generator command line). Confirm the migration is
live before starting, and re-run `scripts/verify-exo-collections.sh` plus a
hands-on launch of a previously case-broken title (e.g. an eXoWin3x game, an
eXoWin9x 86Box CD-ROM title) afterwards.

---

## Operational checklist

- [ ] Pre-flight: `zfs-case-collision-scan.sh` returns 0 for all three roots.
- [ ] Snapshot `@pre-ci-migration` taken.
- [ ] exo-win9x migrated (rename → create insensitive → copy → verify
      wrong-case lookup → destroy `.cs`).
- [ ] exo-win3x migrated (same).
- [ ] exo-dos migrated (same; allow ~75 min for the copy).
- [ ] One game per collection launched on a kiosk (ideally a previously
      case-broken title).
- [ ] Post-migration code cleanup scoped as a separate follow-up (do not mix
      into the migration window).
