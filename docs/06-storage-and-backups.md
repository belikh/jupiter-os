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

`rpool` (one disk, ⚠️ placeholder device path in `disko.nix` — must be
replaced before install):

| Dataset | Mountpoint | Notes |
|---|---|---|
| `root` | `/` | |
| `nix` | `/nix` | |
| `var` | `/var` | n8n state + libvirt VM images; backed up via restic |

No redundancy here is intentional — the OS is fully reproducible from the
flake; only `/var`'s contents are irreplaceable, and that's covered by
restic.

### `t460s` — single pool, impermanent

`rpool` (`/dev/nvme0n1`, declared by `modules/storage/zfs-impermanent.nix`,
not a per-host `disko.nix`):

| Dataset | Mountpoint | Notes |
|---|---|---|
| `local/root` | `/` | Rolled back to `@blank` snapshot every boot |
| `local/nix` | `/nix` | Survives reboots |
| `safe/persist` | `/persist` | Survives reboots; holds everything `jupiter.core.impermanence` whitelists |

### `dashboards` — single pool, minimal

`rpool` (one disk, ⚠️ placeholder device path in `disko.nix`):

| Dataset | Mountpoint |
|---|---|
| `root` | `/` |
| `nix` | `/nix` |

No bulk data — these are stateless kiosk appliances.

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

**`tank`** — 18TB mirror, hand-created during migration (not disko-managed), imported via `boot.zfs.extraPools` in `modules/zfs-nas.nix`. The new primary data pool:

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

First-time setup per LUN (not automated): `mkfs` each LUN once, then mount
where the consuming service expects its data. As noted in
[02-hosts.md](02-hosts.md#elitedesk-hp-elitedesk-800-g4), the actual DB/Loki
service modules that would consume these LUNs aren't declared in this repo
yet.

## 3. NFS exports (`nas`)

`modules/storage/nas-nfs.nix`:

| Export | Access | Clients |
|---|---|---|
| `/tank/media` | read-only, sync, no_subtree_check | LAN (`10.1.1.0/24`), headscale mesh (`100.64.0.0/10`) |
| `/srv/netboot` | read-only, sync, no_subtree_check | LAN only |

Firewall: TCP 2049.

## 4. SMB shares (`nas`)

`modules/zfs-nas.nix`, NetBIOS name `jupiter-nas`, security mode `user`:

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
and `tank/media` (bulk, recursive). No `syncoid` replication target exists
today — if a second backup pool is added later, it should replicate
`tank/personal` + `tank/backups` onto it.

## 6. Offsite backups (restic)

`modules/backups.nix`:

- **Repository:** `s3:s3.us-west-004.backblazeb2.com/jupiter-os-backups` (default; overridable per host via `jupiter.backups.repository`)
- **Credentials:** sops secrets `restic_password` (local encryption key) and `restic_env` (S3 access key/secret as env vars)
- **Schedule:** nightly at 02:00, ±1h randomized delay
- **Excludes:** `**/tmp`, `**/cache` under any `/var/lib/*`
- **Retention:** `--keep-daily 7 --keep-weekly 4 --keep-monthly 6`

| Host | Paths backed up |
|---|---|
| `lenovo` | `/var/lib/n8n`, `/var/lib/libvirt/images` |
| `nas` | `/tank/personal`, `/tank/backups/homeassistant` |

`dashboards`, `elitedesk`, and `t460s` set no `jupiter.backups.paths` and so
have no offsite backup configured (consistent with being stateless/reproducible
or, for `t460s`, impermanent by design).
