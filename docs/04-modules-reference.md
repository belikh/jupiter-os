# Modules Reference

Every reusable NixOS module lives under `modules/` and is exposed as one or
more options under the `jupiter.*` namespace (per the convention in
`CLAUDE.md`). This page documents each module: its options, defaults, what it
configures, and which hosts currently enable it.

Modules with no `jupiter.*` option are unconditional — every host that
imports them gets the config with no toggle.

## Core

### `modules/common.nix`
No option — the universal baseline. See [01-architecture.md §5](01-architecture.md#5-two-base-layers-commonnix-vs-common-statefulnix).

### `modules/common-stateful.nix`
No option — `common.nix` + bootloader + fallback root filesystem for hosts with local disks.

### `modules/core/impermanence.nix`
```
jupiter.core.impermanence.enable           (bool, default false)
jupiter.core.impermanence.persistPath      (string, default "/persist")
jupiter.core.impermanence.persistAdminHome (bool, default true)
jupiter.core.impermanence.extraDirectories (list of string, default [])
jupiter.core.impermanence.extraFiles       (list of string, default [])
jupiter.core.impermanence.users            (attrset of { directories, files })
```
Wraps `environment.persistence."${persistPath}"` (from the `impermanence`
flake input): always persists `/var/log`, `/var/lib/nixos`,
`/var/lib/systemd/coredump`, `/var/lib/libvirt`, NetworkManager connections,
`/var/lib/sops-nix`, the machine-id, and the SSH host key. When
`persistAdminHome` is on (default) it also keeps user `io`'s home dirs
(`Documents`, `.config`, `.ssh`, `.gemini`, `.claude`, …). `extraDirectories`/
`extraFiles`/`users` add host-specific paths — e.g. the kiosks turn
`persistAdminHome` off and persist only the `kiosk` account's Chromium profile.

**Enabled by:** `himalia` (admin home) and the dashboard kiosks (`metis`/`adrastea`/`amalthea`/`thebe`, kiosk profile only).

### `modules/core/branding.nix`
```
jupiter.branding.enable   (bool, default false)
```
RobCo Industries / Fallout-themed boot experience: GRUB (with the
`fallout-grub-theme` fetched from GitHub), green-phosphor console palette,
verbose `preDeviceCommands` boot banner, RobCo-styled MOTD, and (when
`jupiter.desktop.enable` is also true) the `ly` TTY display manager in place
of `greetd`.

**Enabled by:** `ganymede`, `europa`, `himalia`. Off elsewhere (the dashboard
kiosks keep a fast plain `systemd-boot` menu; `callisto` is a bootloader-less
netboot node).

## Desktop

### `modules/desktop/default.nix`
```
jupiter.desktop.enable      (bool, default false)
jupiter.desktop.compositor  (enum ["niri" "gnome" "none"], default "niri")
```
See [03-software-inventory.md §4](03-software-inventory.md#4-desktop-class-currently-himalia) for the full package list per compositor choice.

**Enabled by:** `himalia` (`compositor = "niri"`).

## Storage

### `modules/storage/zfs-profiles.nix`
```
jupiter.storage.profile  (enum ["none" "impermanent" "stateful" "minimal"], default "none")
jupiter.storage.disk     (string, default "/dev/disk/by-id/REPLACE-ME")
jupiter.storage.espSize  (string, default "1G")
```
One shared ZFS-on-root disko layout, selected per host by `profile`, replacing
the old per-host `disko.nix` boilerplate on the simple single-OS-disk hosts:

| Profile | Datasets | Root behaviour |
|---|---|---|
| `impermanent` | `local/root` (+`@blank`), `local/nix`, `safe/persist` | rolled back to `@blank` each boot (erase-your-darlings) |
| `stateful` | `root`, `nix`, `var` | persistent, no rollback |
| `minimal` | `root`, `nix` | persistent, no rollback |
| `none` | — | host declares its own layout / is diskless |

The `impermanent` profile also installs the initrd-stage rollback service
(`zfs rollback -r rpool/local/root@blank` before `sysroot.mount`) and pairs
with `jupiter.core.impermanence` to decide what survives. An assertion blocks
the build while `disk` is still the `REPLACE-ME` placeholder.

**Enabled by:** `himalia` + the dashboard kiosks (`impermanent`), `ganymede`
(`stateful`). `europa` keeps its bespoke `disko.nix` and leaves `profile = "none"`.

### `modules/storage/zfs-nas.nix`
No option — unconditional. Sets `boot.supportedFilesystems = [ "zfs" ]`,
imports the hand-created `tank`/`europa` pools via `boot.zfs.extraPools`,
enables `services.zfs.autoScrub`/`trim`, and declares the three Samba shares
(`media`, `personal`, `archive`) plus `samba-wsdd`.

**Imported by:** `europa` only.

### `modules/storage/sanoid.nix`
No option — unconditional. Snapshot templates `important`
(hourly 36 / daily 30 / monthly 6 / yearly 1) applied recursively to
`tank/personal`, `tank/backups`, `tank/vm`; template `bulk`
(daily 7 / monthly 1) applied to `tank/media`. No `syncoid` replication
target is configured (`europa` is a frozen archive, not a backup pool).

**Imported by:** `europa` only.

### `modules/storage/zfs-tuning.nix`
No option — unconditional. Caps ZFS ARC at ~11GiB
(`zfs_arc_max=11811160064`), sets `vm.swappiness=10`, bumps TCP socket
buffers for 1GbE throughput, and tunes Samba (`sendfile`, async I/O,
`TCP_NODELAY`, min protocol SMB2, multichannel off since the link is a single
bonded interface).

**Imported by:** `europa` only.

### `modules/storage/nas-nfs.nix`
No option — unconditional. `services.nfs.server`, exporting `/tank/media`
(read-only, LAN + headscale mesh), `/srv/netboot` (read-only, LAN), and
`/tank/backups/callisto` (**read-write**, `callisto` only — its backup spool,
§8 of the storage doc). Firewall: TCP 2049.

**Imported by:** `europa` only.

### `modules/storage/iscsi.nix`
```
jupiter.nas.iscsi.enable      (bool, default false)
jupiter.nas.iscsi.targetIqn   (string, default "iqn.2026-06.au.jupiter:europa.target0")
jupiter.nas.iscsi.luns        (list of { name, dev, initiatorIqn })
```
Generates an LIO `services.target` config: one block backstore per LUN (WWN
derived from a SHA-256 hash of the LUN name), one ACL per LUN mapping it to
the consuming host's initiator IQN. Firewall: TCP 3260. (`jupiter.nas.*` is a
role-based option namespace — "the NAS" — independent of the host's actual
name, `europa`.)

**Enabled by:** `europa`, with two LUNs — `db` (`/dev/zvol/rpool/db`) and `loki`
(`/dev/zvol/rpool/loki`), both ACL'd to `iqn.2026-06.au.jupiter:callisto`
(callisto's initiator IQN).

### `modules/storage/backup.nix`
```
jupiter.backup.enable    (bool, default false — defaulted on by the stateful storage profile)
jupiter.backup.datasets  (list of string, default by profile; stateful → [ "rpool/var" ])
```
Per-host declaration that this host's state should reach the central data store
(europa) and thence offsite. The source side: when enabled, authorizes
europa's syncoid pull key (`site.backupHub`, restricted to europa's address)
for root, and asserts `datasets` is non-empty. Europa's side is *derived* —
`flake.nix`'s `backupHubModule` reads every host's `jupiter.backup` and
generates the replication sources, so a new state-holding host needs **no
edit on europa**.

**Enabled by:** `ganymede` (auto, via the `stateful` profile). Off elsewhere.

### `modules/storage/replication.nix`
```
jupiter.replication.enable     (bool, default false)
jupiter.replication.sshKeyPath (path — syncoid's private key, usually a sops secret)
jupiter.replication.interval   (string, default "hourly")
jupiter.replication.sources    (attrset of { remote, sourceDataset, targetDataset })
```
Pull-based ZFS replication via `services.syncoid`: the puller logs into each
source over SSH and pulls `sourceDataset` to `targetDataset` on a timer. syncoid
takes its own pre-send snapshot, so sources need no snapshot policy. The module
header documents the one-time provisioning (keypair → sops, authorize the public
key on each source, `zfs allow` send rights).

**Enabled by:** `europa` (the puller). Its `sources` are not listed by hand —
they are derived from the fleet's `jupiter.backup` declarations by
`flake.nix`'s `backupHubModule`. Today that resolves to `ganymede:rpool/var`
→ `tank/backups/ganymede-var` hourly. See
[06-storage-and-backups.md §7](06-storage-and-backups.md#7-server-state-replication-syncoid--europa--auto-wired).

## Network

### `modules/network/nas-bond.nix`
```
jupiter.nas.bond.enable      (bool, default false)
jupiter.nas.bond.interfaces  (list of string, default ["enp2s0f0" "enp2s0f1"])
jupiter.nas.bond.mtu         (int, default 1500)
```
802.3ad (LACP) bonding across the NAS's two 1GbE ports
(`xmit_hash_policy = "layer3+4"`, `lacp_rate = "fast"`). The matching
UniFi-switch-side LACP config must exist first, or europa loses network
connectivity when this is enabled.

**Set by:** `europa`, currently `enable = false` (not yet turned on).

### `modules/network/dns.nix`
```
jupiter.dns.enable           (bool, default false)
jupiter.dns.domain           (string, default "home.jupiter.au")
jupiter.dns.allowedNetworks  (list of string, default ["127.0.0.0/8" "::1/128"])
jupiter.dns.records          (attrset of fqdn -> ipv4)
```
Two cooperating services:

- **unbound** — authoritative for the internal split-horizon zone
  (`local-zone`/`local-data` built from `jupiter.dns.records`), DNSSEC
  validation, aggressive caching/prefetch, and a hard requirement that it is
  a *pure forwarder* to `dnscrypt-proxy` for everything else (no direct
  recursion to the public internet — see [05-networking.md](05-networking.md)).
- **dnscrypt-proxy** — listens on `127.0.0.1:5353`, anonymized DNSCrypt
  routing (`anonymized_dns.routes`, `via = ["*"]`), DNSSEC/no-log/no-filter
  required upstreams only.

Firewall: TCP+UDP 53.

**Enabled by:** `ganymede`, with `home.jupiter.au` and `allowedNetworks`
covering the default LAN, IoT VLAN, Cameras VLAN, and the headscale mesh
range — see [02-hosts.md](02-hosts.md#ganymede) for the exact CIDR list.

### `modules/network/headscale.nix`
No option — unconditional `services.headscale`. Port 8080, `magic_dns`
enabled, base domain `jupiter.mesh`, mesh clients told to use `10.1.1.20` for
DNS, `ip_prefixes` `100.64.0.0/10` + `fd7a:115c:a1e0::/48`. Firewall: TCP 8080.

**Imported by:** `ganymede` only — the single mesh control plane, exposed
publicly via the Cloudflare Tunnel (`headscale.jupiter.au`).

### `modules/network/cloudflared.nix`
No option — unconditional. One named tunnel
(`aa1088b8-a0e1-4073-8567-6a9bf5fb4bd7`), credentials from sops secret
`cloudflare_cert`, ingress rules for `headscale.jupiter.au`, `n8n.jupiter.au`,
`ha.jupiter.au` (all `http_status:404` default catch-all).

**Imported by:** `ganymede` only.

### `modules/network/pxe-server.nix`
```
jupiter.pxe.enable    (bool, default false)
jupiter.pxe.kernel     (string, path/URL to bzImage)
jupiter.pxe.initrd     (string, path/URL to initrd)
jupiter.pxe.cmdLine    (string, default "loglevel=4")
```
Wraps `services.pixiecore` in `"boot"` mode (acts as DHCP proxy + serves the
kernel/initrd itself — no separate webroot needed).

**Enabled by:** `ganymede`, via the `pxeModule` defined in `flake.nix`, which
sources `kernel`/`initrd`/`cmdLine` directly from
`self.nixosConfigurations.callisto.config.system.build` — see
[01-architecture.md §3](01-architecture.md#3-the-mkhost-pattern-flakenix).

## Services

### `modules/services/syncthing.nix`
```
jupiter.services.syncthing.enable   (bool, default false)
jupiter.services.syncthing.dataDir  (string, default "/home/io")
```
`dataDir` is the sync root + config/index location. Personal machines keep the
default (`/home/io`); **europa (the NAS hub) sets it to `/tank/personal`** so
the canonical synced copy lands on mirrored, snapshotted, offsite storage
rather than the OS disk.
`services.syncthing` for user `io`, GUI bound to `0.0.0.0:8384` (reachable
over LAN/headscale), device/folder management left to the WebUI
(`overrideDevices`/`overrideFolders = false`). Also drops a `.stignore`
template into `/home/io` on first activation that excludes most dotfiles/caches
but explicitly re-includes `.claude` and `.gemini`. Firewall: TCP 8384/22000,
UDP 22000/21027.

**Enabled by:** `europa`, `himalia`.

### `modules/services/tcxwave-power-tuning.nix`
No option — unconditional. Shared by all 4 dashboard kiosks. See the full
breakdown in
[03-software-inventory.md §3](03-software-inventory.md#dashboard-kiosks-metis-adrastea-amalthea-thebe-tcx-wave-4)
and [02-hosts.md](02-hosts.md#dashboard-kiosks-metis-adrastea-amalthea-thebe).

**Imported by:** `metis`, `adrastea`, `amalthea`, `thebe`.

### `modules/services/home-assistant-vm.nix`
No option — unconditional. `virtualisation.libvirtd` with
`qemu_kvm`/`runAsRoot`/`swtpm`; ships `virt-manager`, `libvirt`, `qemu_kvm`
CLI tools. Network bridging is left to the host (`hosts/ganymede` declares
`br0` itself) to avoid NIC-name mismatches.

**Imported by:** `ganymede` only.

### `modules/services/n8n.nix`
```
jupiter.services.n8n.database.enable       (bool, default false)
jupiter.services.n8n.database.host         (string)
jupiter.services.n8n.database.{port,name,user}
jupiter.services.n8n.database.passwordFile (path — sops secret)
```
`services.n8n` (always on for the importing host). `allowUnfree` is turned on
(n8n's license is "sustainable use", which Nixpkgs treats as unfree). Listens on
`127.0.0.1:5678` behind the Cloudflare Tunnel; `WEBHOOK_URL =
"https://n8n.jupiter.au"`. With `database.enable`, n8n is pointed at PostgreSQL
(`DB_TYPE=postgresdb`, password via `DB_POSTGRESDB_PASSWORD_FILE`) instead of
the bundled SQLite.

**Imported by:** `ganymede`, which enables the Postgres backend against
`callisto`.

### `modules/services/postgresql.nix`
```
jupiter.services.postgresql.enable    (bool, default false)
jupiter.services.postgresql.dataDir   (path, default "/var/lib/postgresql")
jupiter.services.postgresql.package   (package, default pkgs.postgresql_16)
jupiter.services.postgresql.databases (attrset of { passwordFile, allowedClients })
```
`services.postgresql` with its data directory under `dataDir` (on `callisto`
the iSCSI `db` LUN) and `RequiresMountsFor` so it waits for that mount. Each
entry in `databases` provisions a login role + owned database of that name,
sets the role password from `passwordFile` (a sops secret, applied by the
`postgresql-jupiter-roles` oneshot), and opens scram-sha-256 access from each
CIDR in `allowedClients` (firewall + `enableTCPIP` follow automatically). Local
peer auth still works for admin.

**Enabled by:** `callisto`, with `homeassistant` (reachable from the HA VM) and
`n8n` (reachable from ganymede) databases.

### `modules/services/loki.nix`
```
jupiter.services.loki.enable     (bool, default false)
jupiter.services.loki.dataDir    (path, default "/var/lib/loki")
jupiter.services.loki.httpPort   (port, default 3100)
jupiter.services.loki.syslogPort (port, default 514)
```
`services.loki` (single-node, filesystem storage under `dataDir` — on
`callisto` the iSCSI `loki` LUN) plus a `services.alloy` (grafana-alloy)
syslog receiver that ingests the Wyze cams' forwarded logs (RFC5424/TCP on
`syslogPort`) and pushes them to Loki. Firewall: TCP `httpPort` + `syslogPort`.

**Enabled by:** `callisto`.

### `modules/services/state-backup.nix`
```
jupiter.services.stateBackup.enable     (bool, default false)
jupiter.services.stateBackup.spoolDir   (path — must be on backed-up storage)
jupiter.services.stateBackup.interval   (string, default "hourly")
jupiter.services.stateBackup.keep       (int, default 24 — postgres dumps retained)
jupiter.services.stateBackup.postgres   (bool, default false — hourly pg_dumpall)
jupiter.services.stateBackup.rsyncPaths (list of string — dirs mirrored into the spool)
```
A timer that lands a restic-friendly *logical* copy of a host's service state
into `spoolDir` (typically an NFS mount of `tank/backups`), so hosts whose data
sits on raw iSCSI zvols still get snapshotted + offsite via europa. `pg_dumpall`
for Postgres (transactionally consistent), `rsync --delete` for file dirs.

**Enabled by:** `callisto` (postgres + `/var/lib/loki` → `europa:/tank/backups/callisto`).

### `modules/services/backups.nix`
```
jupiter.backups.paths        (list of string, default [])
jupiter.backups.repository   (string, default "s3:s3.us-west-004.backblazeb2.com/jupiter-os-backups")
```
`services.restic.backups.daily-cloud-backup`: nightly at 02:00
(±1h randomized delay), excludes `**/tmp`/`**/cache`, password + S3
credentials from sops secrets `restic_password`/`restic_env`, retention
`--keep-daily 7 --keep-weekly 4 --keep-monthly 6`.

**Used by:** `europa` only (`/tank/personal`, `/tank/backups/homeassistant`,
`/tank/backups/ganymede`) — the fleet's single offsite egress. Other hosts'
state reaches the cloud by first replicating to europa (`jupiter.replication`).

## Home

### `modules/home/` (`default.nix` + `io.nix`)
```
jupiter.home.enable   (bool, default false)
```
Opt-in home-manager environment for user `io` — the portable identity shared
across personal machines. `default.nix` wires home-manager
(`useGlobalPkgs`/`useUserPackages`, `users.io = import ./io.nix`); `io.nix`
holds the machine-agnostic config: user packages, git/bash/direnv, and a shared
niri config written as a plain `~/.config/niri/config.kdl` (no dependency on a
compositor HM module). Data directories are deliberately *not* managed here —
they roam via Syncthing with europa as hub.

**Enabled by:** `himalia` (and the `elara`/`carme` scaffolds).

## How to add a new module

Per `CLAUDE.md`: put new cross-host functionality in `modules/` behind a
`jupiter.*` option, then have hosts opt in via the toggle rather than
inlining the underlying config. Keep flake-level module wiring (new
flake inputs that need injecting into every host) going through the
`mkHost` lexical closure in `flake.nix` rather than `specialArgs`.
