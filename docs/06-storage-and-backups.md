# Storage & Backups

Three layers of data protection are used across the fleet, deliberately
scoped differently per layer (see the comments in
`modules/storage/sanoid.nix`):

1. **ZFS mirrors** — survive a single drive failure.
2. **sanoid snapshots** — survive "oops, rm -rf", accidental edits, ransomware.
3. **restic → Backblaze B2** — survives losing the whole box/site; covers only the irreplaceable, reasonably-sized subset of data.

Bulk/expendable datasets (media, surveillance, downloads) are deliberately
*not* snapshotted or backed up offsite — they're either reproducible or
disposable, and snapshotting churny data is wasted space.

## 1. ZFS layout by host

### `ganymede` — single pool, no redundancy

`rpool` (`jupiter.storage.profile = "stateful"`; one disk, ⚠️ placeholder
device path — must be replaced before install):

| Dataset | Mountpoint | Notes |
|---|---|---|
| `root` | `/` | |
| `nix` | `/nix` | |
| `var` | `/var` | n8n state + libvirt VM images; backed up via restic |

No redundancy here is intentional — the OS is fully reproducible from the
flake; only `/var`'s contents are irreplaceable, and that's covered by
restic.

### `himalia` — single pool, impermanent

`rpool` (`jupiter.storage.profile = "impermanent"`, `disk = "/dev/nvme0n1"`):

| Dataset | Mountpoint | Notes |
|---|---|---|
| `local/root` | `/` | Rolled back to `@blank` snapshot every boot |
| `local/nix` | `/nix` | Survives reboots |
| `safe/persist` | `/persist` | Survives reboots; holds everything `jupiter.core.impermanence` whitelists |

### Dashboard kiosks (`metis`, `adrastea`, `amalthea`, `thebe`) — single pool each, impermanent

Each kiosk has its own `rpool` (`jupiter.storage.profile = "impermanent"`;
one disk per unit, ⚠️ placeholder device path per host):

| Dataset | Mountpoint | Notes |
|---|---|---|
| `local/root` | `/` | Rolled back to `@blank` every boot |
| `local/nix` | `/nix` | Survives reboots |
| `safe/persist` | `/persist` | Survives reboots; holds only the minimal system set + the `kiosk` Chromium profile |

Stateless kiosk appliances — nothing irreplaceable lives here, so each box
always boots pristine and can't accumulate drift.

### `europa` — three pools

**`rpool`** — OS SSD (Crucial MX500 500GB, `ata-CT500MX500SSD1_1921E206022D`), disko-managed, single disk (no redundancy — reproducible OS + non-irreplaceable fast-tier data):

| Dataset | Type | Mountpoint / use | Notes |
|---|---|---|---|
| `root` | fs | `/` | |
| `nix` | fs | `/nix` | |
| `var` | fs | `/var` | |
| `db` | zvol, 64G | — | `volblocksize=16k`; exported to `callisto` over iSCSI |
| `loki` | zvol, 100G | — | `volblocksize=16k`; exported to `callisto` over iSCSI |
| `netboot` | fs | `/srv/netboot` | Diskless/netboot roots; served read-only over NFS |
| `scratch` | fs | `/srv/scratch` | Expendable local scratch (e.g. restic cache) |

**`tank`** — 18TB mirror, hand-created during migration (not disko-managed), imported via `boot.zfs.extraPools` in `modules/storage/zfs-nas.nix`. The new primary data pool:

| Dataset | sanoid policy | Backed up offsite? | Served via |
|---|---|---|---|
| `tank/personal` | `important` (recursive) | Yes (restic) | Samba `personal` |
| `tank/backups` | `important` (recursive) | Yes — `tank/backups/homeassistant` specifically (restic) | — |
| `tank/vm` | `important` (recursive) | No | — |
| `tank/media` | `bulk` | No | Samba `media`, NFS `/tank/media` (ro) |
| `tank/surveillance` | none | No | — |
| `tank/downloads` | none | No | — |
| `tank/archive` | none | No | — |

**`europa`** — 10TB mirror, hand-created, imported the same way. Frozen
legacy archive, set read-only during migration, never restructured. Exposed
read-only via Samba's `archive` share at `/europa`.

## 2. iSCSI (`europa` → `callisto`)

`modules/storage/iscsi.nix` (`jupiter.nas.iscsi` — a role-based option
namespace, independent of europa's actual hostname) stands up an LIO target
on `europa`:

- Target IQN: `iqn.2026-06.au.jupiter:nas.target0` (kept as a fixed protocol identity, not renamed alongside the host)
- Portal: `0.0.0.0:3260`
- LUNs: `db` (`/dev/zvol/rpool/db`), `loki` (`/dev/zvol/rpool/loki`)
- ACL: both LUNs mapped only to initiator `iqn.2026-06.au.jupiter:elitedesk` (callisto's initiator IQN, likewise kept as-is)

`callisto` runs the matching initiator (`services.openiscsi`,
`enableAutoLoginOut = true`, `discoverPortal = "europa.home.jupiter.au:3260"`),
auto-discovering and logging into the target at boot. A static
`networking.hosts` entry for `europa.home.jupiter.au` avoids a race between the
boot-time iSCSI login and the DNS resolver coming up.

The LUNs are consumed on `callisto` by `jupiter.services.postgresql` (the `db`
LUN at `/var/lib/postgresql`) and `jupiter.services.loki` (the `loki` LUN at
`/var/lib/loki`), mounted by label with `_netdev,nofail`. First-time setup
(not automated): `mkfs.ext4 -L db` / `-L loki` each attached LUN once, then the
declarative mounts pick them up on every boot.

## 3. NFS exports (`europa`)

`modules/storage/nas-nfs.nix`:

| Export | Access | Clients |
|---|---|---|
| `/tank/media` | read-only, sync, no_subtree_check | LAN (`10.1.1.0/24`), headscale mesh (`100.64.0.0/10`) |
| `/srv/netboot` | read-only, sync, no_subtree_check | LAN only |
| `/tank/backups/elitedesk` | **read-write**, sync, no_root_squash | `callisto` (`10.1.1.21`) only — dataset name kept as "elitedesk", already provisioned |

Firewall: TCP 2049. The read-write export is callisto's backup spool (§8).

## 4. SMB shares (`europa`)

`modules/storage/zfs-nas.nix`, NetBIOS name `jupiter-nas`, security mode `user`:

| Share | Path | Access |
|---|---|---|
| `media` | `/tank/media` | read-write, user `io` only |
| `personal` | `/tank/personal` | read-write, user `io` only |
| `archive` | `/europa` | **read-only**, user `io` only |

`samba-wsdd` is enabled so europa shows up in Windows network discovery.
Samba is additionally tuned in `modules/storage/zfs-tuning.nix` for the weak
NAS CPU (sendfile, async I/O, `TCP_NODELAY`, SMB2 minimum, multichannel
disabled since the link is logically single — see
[01-architecture.md](01-architecture.md) and
[04-modules-reference.md](04-modules-reference.md#modulesstoragezfs-tuningnix)).

## 5. Snapshots (sanoid, `europa` only)

Two templates (`modules/storage/sanoid.nix`):

| Template | hourly | daily | monthly | yearly |
|---|---|---|---|---|
| `important` | 36 | 30 | 6 | 1 |
| `bulk` | 0 | 7 | 1 | 0 |

Applied to `tank/personal`, `tank/backups`, `tank/vm` (important, recursive)
and `tank/media` (bulk, recursive). `tank/backups` is recursive, so the
server state replicated in under `tank/backups/<host>` (see §7) inherits the
`important` policy automatically. No *outbound* `syncoid` target to a second
pool exists today — if one is added later it should replicate `tank/personal`
+ `tank/backups` onto it.

## 6. Offsite backups (restic)

`modules/services/backups.nix`:

- **Repository:** `s3:s3.us-west-004.backblazeb2.com/jupiter-os-backups` (default; overridable per host via `jupiter.backups.repository`)
- **Credentials:** sops secrets `restic_password` (local encryption key) and `restic_env` (S3 access key/secret as env vars)
- **Schedule:** nightly at 02:00, ±1h randomized delay
- **Excludes:** `**/tmp`, `**/cache` under any `/var/lib/*`
- **Retention:** `--keep-daily 7 --keep-weekly 4 --keep-monthly 6`

| Host | Paths backed up |
|---|---|
| `europa` | `/tank/personal`, `/tank/backups` (the whole tree — replicated host state + callisto's backup spool) |

**Europa is the only host with offsite egress** — every other host's
irreplaceable state reaches the cloud by first landing on europa (see §7, §8),
not by backing up directly. `ganymede`, the dashboard kiosks, `callisto`, and
`himalia` set no `jupiter.backups.paths`.

## 7. Server-state replication (syncoid → europa) — auto-wired

Europa is the central data store: any host with local persistent state
replicates to it hourly, and europa is the only host with offsite egress.
**This wiring is automatic — you never edit europa to add a host:**

- Each host declares `jupiter.backup` (`modules/storage/backup.nix`). The
  `stateful` storage profile defaults it on with `datasets = [ "rpool/var" ]`;
  appliances/laptops (impermanent) leave it off (they roam via Syncthing), and
  diskless hosts whose data already lives on europa's iSCSI don't need it.
- `modules/storage/backup.nix` auto-authorizes europa's syncoid pull key
  (`site.backupHub`, restricted to europa's address) for root on each enabled
  host.
- `flake.nix`'s `backupHubModule` reads every host's `jupiter.backup` and
  generates europa's `jupiter.replication.sources` — one syncoid command per
  declared dataset, landing at `tank/backups/<host>-<leaf>`.

So the live mapping is derived, not listed. Today that's:

| Source | Source dataset | Lands at | Interval |
|---|---|---|---|
| `ganymede` | `rpool/var` (n8n flows + libvirt images) | `tank/backups/ganymede-var` | hourly |

syncoid (pull mode on europa) takes its own pre-send snapshot, so sources need
no snapshot policy. The landing datasets sit under `tank/backups`, which is
recursive in the `important` sanoid policy and is backed up wholesale to the
offsite repo (§6) — so a new replicated host is snapshotted + offsite with no
further config. One-time provisioning: the `syncoid_ssh_key` sops secret on
europa and its public key in `site.backupHub.syncoidPublicKey`.

## 8. Diskless-host state backup (callisto → europa)

Syncoid (§7) replicates ZFS *datasets*, but `callisto`'s Postgres and Loki live
on raw iSCSI **zvols** (block devices) that restic can't walk and syncoid would
only copy block-for-block. So `callisto` instead lands a restic-friendly
*logical* copy on europa, where the existing sanoid + restic pick it up — the
mechanism the disko comment always intended ("DB durability is the elitedesk's
job; loki snapshot+restic to tank").

`modules/services/state-backup.nix` (`jupiter.services.stateBackup`) runs hourly
on `callisto` and writes into `/var/backup`, an NFS mount of
`europa:/tank/backups/elitedesk` (`x-systemd.automount`, so the diskless boot
never waits on europa):

| What | How | Lands at |
|---|---|---|
| PostgreSQL (HA recorder + n8n) | `pg_dumpall` \| gzip, keep last 24 | `tank/backups/elitedesk/postgres/` |
| Loki chunks | `rsync -a --delete /var/lib/loki` | `tank/backups/elitedesk/loki/` |

Because it's under `tank/backups`, it inherits the `important` sanoid policy and
the wholesale restic offsite path (§6) — **no gap**: the live data is on the SSD
zvols (fast), and a consistent, restorable copy is snapshotted locally and
shipped offsite. One-time provisioning: `zfs create tank/backups/elitedesk` on
europa.
