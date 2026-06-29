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

### `lenovo` — single pool, no redundancy

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

### `t460s` — single pool, impermanent

`rpool` (`jupiter.storage.profile = "impermanent"`, `disk = "/dev/nvme0n1"`):

| Dataset | Mountpoint | Notes |
|---|---|---|
| `local/root` | `/` | Rolled back to `@blank` snapshot every boot |
| `local/nix` | `/nix` | Survives reboots |
| `safe/persist` | `/persist` | Survives reboots; holds everything `jupiter.core.impermanence` whitelists |

### `dashboards` — single pool, impermanent

`rpool` (`jupiter.storage.profile = "impermanent"`; one disk, ⚠️ placeholder
device path):

| Dataset | Mountpoint | Notes |
|---|---|---|
| `local/root` | `/` | Rolled back to `@blank` every boot |
| `local/nix` | `/nix` | Survives reboots |
| `safe/persist` | `/persist` | Survives reboots; holds only the minimal system set + the `kiosk` Chromium profile |

Stateless kiosk appliances — nothing irreplaceable lives here, so the box
always boots pristine and can't accumulate drift.

### `nas` — three pools

**`rpool`** — OS SSD (Crucial MX500 500GB, `ata-CT500MX500SSD1_1921E206022D`), disko-managed, single disk (no redundancy — reproducible OS + non-irreplaceable fast-tier data):

| Dataset | Type | Mountpoint / use | Notes |
|---|---|---|---|
| `root` | fs | `/` | |
| `nix` | fs | `/nix` | |
| `var` | fs | `/var` | |
| `db` | zvol, 64G | — | `volblocksize=16k`; exported to `elitedesk` over iSCSI |
| `loki` | zvol, 100G | — | `volblocksize=16k`; exported to `elitedesk` over iSCSI |
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

## 2. iSCSI (`nas` → `elitedesk`)

`modules/storage/iscsi.nix` (`jupiter.nas.iscsi`) stands up an LIO target on
`nas`:

- Target IQN: `iqn.2026-06.au.jupiter:nas.target0`
- Portal: `0.0.0.0:3260`
- LUNs: `db` (`/dev/zvol/rpool/db`), `loki` (`/dev/zvol/rpool/loki`)
- ACL: both LUNs mapped only to initiator `iqn.2026-06.au.jupiter:elitedesk`

`elitedesk` runs the matching initiator (`services.openiscsi`,
`enableAutoLoginOut = true`, `discoverPortal = "nas.home.jupiter.au:3260"`),
auto-discovering and logging into the target at boot. A static
`networking.hosts` entry for `nas.home.jupiter.au` avoids a race between the
boot-time iSCSI login and the DNS resolver coming up.

The LUNs are consumed on `elitedesk` by `jupiter.services.postgresql` (the `db`
LUN at `/var/lib/postgresql`) and `jupiter.services.loki` (the `loki` LUN at
`/var/lib/loki`), mounted by label with `_netdev,nofail`. First-time setup
(not automated): `mkfs.ext4 -L db` / `-L loki` each attached LUN once, then the
declarative mounts pick them up on every boot.

## 3. NFS exports (`nas`)

`modules/storage/nas-nfs.nix`:

| Export | Access | Clients |
|---|---|---|
| `/tank/media` | read-only, sync, no_subtree_check | LAN (`10.1.1.0/24`), headscale mesh (`100.64.0.0/10`) |
| `/srv/netboot` | read-only, sync, no_subtree_check | LAN only |

Firewall: TCP 2049.

## 4. SMB shares (`nas`)

`modules/storage/zfs-nas.nix`, NetBIOS name `jupiter-nas`, security mode `user`:

| Share | Path | Access |
|---|---|---|
| `media` | `/tank/media` | read-write, user `io` only |
| `personal` | `/tank/personal` | read-write, user `io` only |
| `archive` | `/europa` | **read-only**, user `io` only |

`samba-wsdd` is enabled so the NAS shows up in Windows network discovery.
Samba is additionally tuned in `modules/storage/zfs-tuning.nix` for the weak
NAS CPU (sendfile, async I/O, `TCP_NODELAY`, SMB2 minimum, multichannel
disabled since the link is logically single — see
[01-architecture.md](01-architecture.md) and
[04-modules-reference.md](04-modules-reference.md#modulesstoragezfs-tuningnix)).

## 5. Snapshots (sanoid, `nas` only)

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
| `nas` | `/tank/personal`, `/tank/backups/homeassistant`, `/tank/backups/lenovo` |

The **NAS is the only host with offsite egress** — every other host's
irreplaceable state reaches the cloud by first landing on the NAS (see §7),
not by backing up directly. `lenovo`, `dashboards`, `elitedesk`, and `t460s`
set no `jupiter.backups.paths`.

## 7. Server-state replication (syncoid → NAS) — auto-wired

The NAS is the central data store: any host with local persistent state
replicates to it hourly, and the NAS is the only host with offsite egress.
**This wiring is automatic — you never edit the NAS to add a host:**

- Each host declares `jupiter.backup` (`modules/storage/backup.nix`). The
  `stateful` storage profile defaults it on with `datasets = [ "rpool/var" ]`;
  appliances/laptops (impermanent) leave it off (they roam via Syncthing), and
  diskless hosts whose data already lives on NAS iSCSI don't need it.
- `modules/storage/backup.nix` auto-authorizes the NAS's syncoid pull key
  (`site.backupHub`, restricted to the NAS address) for root on each enabled
  host.
- `flake.nix`'s `backupHubModule` reads every host's `jupiter.backup` and
  generates the NAS's `jupiter.replication.sources` — one syncoid command per
  declared dataset, landing at `tank/backups/<host>-<leaf>`.

So the live mapping is derived, not listed. Today that's:

| Source | Source dataset | Lands at | Interval |
|---|---|---|---|
| `lenovo` | `rpool/var` (n8n flows + libvirt images) | `tank/backups/lenovo-var` | hourly |

syncoid (pull mode on the NAS) takes its own pre-send snapshot, so sources need
no snapshot policy. The landing datasets sit under `tank/backups`, which is
recursive in the `important` sanoid policy and is backed up wholesale to the
offsite repo (§6) — so a new replicated host is snapshotted + offsite with no
further config. One-time provisioning: the `syncoid_ssh_key` sops secret on the
NAS and its public key in `site.backupHub.syncoidPublicKey`.
