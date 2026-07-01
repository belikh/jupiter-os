# Roadmap & structural decisions

Working notes for the structure review started on the
`claude/project-structure-review-txkwlb` branch. Captures the decisions taken
so they survive across sessions. This is a planning doc, not reference docs —
it should shrink as items land and the decisions fold into the real docs.

## Guiding principles (decided)

- **`jupiter.*` toggles everywhere.** Every host configures storage,
  impermanence, desktop, etc. through the `jupiter.*` option namespace — no
  hand-rolled per-host config where a toggle fits. (Today only `himalia` does
  this; the others predate it.)
- **Europa is the data hub.** All host state lands on europa (the NAS) first;
  europa is the *single* offsite egress point (restic → Backblaze B2). No
  host backs up directly offsite.
- **Impermanence is for appliances/workstations, not servers.** Erase-your-
  darlings on the laptop and kiosks (kills config drift). Servers keep a
  stateful root so undeclared state can't be silently wiped on reboot.
- **Docs stay high-level.** Architecture, rationale, runbooks — not line-level
  package/dataset tables that duplicate code and drift.

## Storage / impermanence (decided)

Shared `jupiter.storage` module exposing **opinionated profiles** plus an
escape hatch for the odd host:

| Profile | Root | Datasets | Used by |
|---|---|---|---|
| `impermanent` | rolls back to `@blank` each boot | `local/root`, `local/nix`, `safe/persist` | `himalia`, the dashboard kiosks |
| `stateful` | persistent root | `root`, `nix`, `var` | `ganymede` |
| `minimal` | persistent root | `root`, `nix` | (simple disk hosts) |

- **ganymede:** `stateful` — n8n flows + libvirt images persist on a dedicated
  `/var`; no rollback. (Binaries are in `/nix` and always persist regardless.)
- **dashboard kiosks (`metis`/`adrastea`/`amalthea`/`thebe`):** `impermanent`,
  persist set = **minimal + the kiosk user's Chromium profile** (machine-id,
  SSH host key, sops-nix, `/var/log`, Chromium profile).
- **europa:** stays **fully bespoke** — its `disko.nix` keeps the rpool +
  zvols + `netboot`/`scratch` layout; `tank`/`europa` remain hand-created and
  imported via `boot.zfs.extraPools`. The shared module is for the simpler
  hosts.
- `REPLACE-ME` device paths stay unset but get a **friendly assertion**
  pointing at the install runbook instead of a raw eval failure.

## Backups (decided)

- **Mechanism:** `syncoid` (ZFS send/recv over SSH), europa pulls.
- **Source → dest:** server state datasets (e.g. `ganymede:/var`) →
  `tank/backups/<host>` on europa.
- **Frequency:** hourly.
- **Offsite:** `tank/backups` is already in the sanoid `important` policy and
  the restic offsite path, so replicated state inherits snapshots + offsite.
- **Remove** ganymede's direct-to-B2 restic config — europa is the sole egress.

## Roaming desktop (decided direction)

Goal: sit at any personal machine (home, eventually the parents' house) and
log in as if on the home PC.

- **Adopt home-manager** — user `io`'s dotfiles/packages/desktop config managed
  declaratively in the flake, identical across personal machines by rebuild.
- **Portable `$HOME`:** local home on each machine, **Syncthing** mirrors the
  data dirs via europa as hub. Offline-tolerant — important for the parents-house
  node over the headscale mesh. (Config is declarative via home-manager; only
  data is synced.)
- **Identical `niri`** on every personal machine.
- **Hosts in scope:** `himalia` (now), a **home desktop PC** (future slot,
  `elara`), a **parents-house PC** (future slot, `carme`, joins over the
  mesh). Kiosks are appliances by default (dashboard mode) but can present a
  personal session on a VT — they already have the dual-VT dashboard/gaming
  switch (`modules/desktop/dashboard-gaming.nix`); a personal/desktop "mode"
  fits the same pattern.

## Future direction: consolidate servers onto callisto

The longer-term intent is to **move all server roles onto `callisto` and
retire `ganymede`** (repurposed elsewhere). The Postgres-on-callisto +
HA/n8n-as-LAN-consumers wiring is a step in that direction, but it currently
creates a cross-host dependency (ganymede's n8n needs callisto's Postgres,
which needs europa's iSCSI). When the migration happens, n8n / HA / DNS /
headscale / cloudflared / the HA VM move to callisto and these become local
connections. Not started — it's a large move that needs its own plan (and
callisto is diskless/netboot today, so its role/boot story changes).

## Out of scope / deferred

- **Containers** — none wanted for now (libvirt VMs + n8n cover it).
- **Europa's LACP bond** — stays disabled until the UniFi switch-side LACP exists.
- **cloudflare_api_token** — user adds it to `secrets.yaml` when needed.

## Staged PRs

1. ~~**Storage/disko** — parameterized `jupiter.storage` module (profiles),
   full toggle adoption on ganymede/dashboards (europa stays bespoke), kiosk
   impermanence, friendly device-path assertion.~~ **Done** (see below).
2. **Module reshuffle + style** — normalize `modules/` into category subdirs;
   standardize one module idiom (explicit `lib.*`, consistent arg order);
   document the convention in `CLAUDE.md`.
3. **Network single source of truth** — shared VLAN/subnet attrset consumed by
   both `terraform/unifi` and `modules/network/dns.nix` (pending a check that
   terranix can import it cleanly).
4. **CI VM smoke tests** — boot each host in QEMU and assert multi-user.
5. **Backup topology** — syncoid replication to europa; drop direct-B2.
6. **elitedesk services** — DB + Loki + syslog receiver consuming the iSCSI
   LUNs and the Wyze syslog target. (Host later renamed to `callisto`.)
7. **home-manager + roaming** — adopt home-manager for `io`; scaffold the
   future desktop host slots; Syncthing-synced `$HOME` across personal
   machines.

All seven stages are implemented on the branch (one commit each). A **docs
trim** (cut the line-level tables that mirror code) is still outstanding — fold
it in once CI is validating.

### Landed (one commit per item)

- **Inheritance tidy** — base CLI tooling → `common.nix`; `sops.defaultSopsFile`;
  branding opt-in; dropped unused `docker` group; headscale → lenovo only.
- **Stage 1 — storage profiles** — `modules/storage/zfs-profiles.nix`
  (`jupiter.storage.profile`), replacing `zfs-impermanent.nix` + per-host
  `disko.nix`; lenovo→stateful, dashboards/t460s→impermanent, nas bespoke;
  REPLACE-ME assertion; `impermanence.nix` gained per-host persist controls.
- **Stage 2 — module reshuffle** — `modules/` sorted into category subdirs;
  module-style convention documented in `CLAUDE.md`. The 11 modules still on
  `with lib;` at the time (branding, desktop/default, dashboard-gaming,
  impermanence, iscsi, nas-bond, pxe-server, dns, bazzite, mqtt, syncthing)
  are now converted to explicit `lib.mkOption`/`lib.mkIf`/`lib.types`;
  `with pkgs;` (package lists) is unaffected — only `with lib;` was in scope.
  Verified with `make fmt` + `nix flake check` (only pre-existing
  `REPLACE-ME` disk-placeholder assertions remain, unrelated to this change).
- **Stage 3 — network SoT** — `lib/site.nix` shared by `terraform/unifi` and
  `jupiter.dns`.
- **Stage 4 — CI boot tests** — `scripts/boot-smoke.sh` + `boot-test` CI job;
  rollback service guarded for VM builds.
- **Stage 5 — backup topology** — `modules/storage/replication.nix` (syncoid),
  europa pulls `ganymede:rpool/var` hourly; ganymede direct-B2 dropped.
- **Stage 6 — elitedesk services** — `postgresql.nix` + `loki.nix` on the iSCSI
  LUNs; static identity (10.1.1.21) for the syslog target. (Host later renamed
  to `callisto`.)
- **Stage 7 — home-manager + roaming** — `modules/home/` (`jupiter.home.enable`),
  home-manager input + injection, niri config for `io`; `desktop`/
  `parents-desktop` scaffolds (unregistered, later renamed `elara`/`carme`).
- **Postgres consumers** — `jupiter.services.postgresql.databases` (networked
  roles + sops passwords + scram-sha-256); callisto serves `homeassistant`
  (HA VM) and `n8n` (ganymede). n8n migrated off SQLite. HA recorder `db_url` is
  set inside the HAOS VM (not NixOS-managed). Passwords are generated by
  `make gen-secrets` (not hand-set); still needs a one-time n8n SQLite→PG data
  migration.
- **Auto-wired central backup** — `jupiter.backup` (`modules/storage/backup.nix`),
  defaulted on by the `stateful` storage profile; `flake.nix`'s `backupHubModule`
  derives europa's syncoid sources from the fleet, and europa backs up
  `tank/backups` wholesale. New state-holding hosts replicate offsite with no
  edit on europa. Source-side pull key auto-authorized from `site.backupHub`.
- **Generated service credentials** — `make gen-secrets` (`scripts/gen-secrets.sh`)
  produces random, impossible machine-to-machine passwords + the syncoid keypair
  straight into sops; no inter-service password is ever hand-set. Public syncoid
  key committed at `secrets/syncoid_ed25519.pub`, read by `lib/site.nix`.

## Data-durability gaps — all closed

- **callisto DB/Loki** (raw iSCSI zvols restic can't walk) →
  `jupiter.services.stateBackup` lands an hourly `pg_dumpall` + Loki `rsync`
  on `europa:/tank/backups/callisto`.
- **Syncthing hub data** (was on europa's OS disk, unprotected) → europa sets
  `jupiter.services.syncthing.dataDir = "/tank/personal"`, so the canonical
  roaming copy is mirrored, snapshotted, and offsite.

### Detail: callisto DB/Loki

callisto's Postgres + Loki live on raw iSCSI zvols that restic can't walk, so
`modules/services/state-backup.nix` (`jupiter.services.stateBackup`) now runs an
hourly `pg_dumpall` + a Loki `rsync` into an NFS mount of
`europa:/tank/backups/callisto`. That lands under `tank/backups`, so it inherits
the `important` sanoid policy and the wholesale restic offsite path — the live
data stays on the fast SSD zvols while a consistent, restorable copy is
snapshotted + shipped offsite. One-time: `zfs create tank/backups/callisto`.

## Operational maturity gaps (not started)

Surveyed 2026-07-01 by grepping the repo for monitoring/alerting, rollback,
backup-verification, secrets-rotation, and hardening patterns. What exists
today: Loki (`modules/services/loki.nix`, log storage only — no metrics/
dashboards/paging), sanoid snapshot policies + syncoid replication + restic
offsite (`modules/storage/{sanoid,replication,backup}.nix`), CI build +
QEMU boot-smoke tests (`.github/workflows/ci.yml`), headscale mesh VPN,
cloudflared tunnel ingress, `nix.gc.automatic` (common.nix), and NixOS's
built-in generation rollback (free, but manual — nothing auto-reverts a bad
activation). Everything below was checked for and confirmed absent as of
that survey; re-verify before assuming still true.

- **No metrics/alerting stack.** Loki covers logs; nothing scrapes metrics or
  pages on failure (no Prometheus/Grafana/Alertmanager, no ntfy/Pushover/
  healthchecks.io hook anywhere in `modules/`). An outage is currently
  discovered by using the affected service, not by a notification.
- **No post-deploy health check / automated rollback.** `deploy-rs` activates
  and stops there — no boot-counting or watchdog reverts a generation that
  fails to reach multi-user on real hardware (CI's `boot-test` job covers
  this pre-merge in QEMU only, not post-deploy on the actual host).
- **No backup-restore verification.** Syncoid replication + sanoid snapshots +
  restic offsite all exist, but nothing periodically proves a snapshot is
  actually restorable (vs. just "the send/recv succeeded").
- **No secrets rotation.** `make gen-secrets` (`scripts/gen-secrets.sh`) fills
  in missing service-to-service credentials once; nothing rotates the
  sops-nix age keys or the generated passwords/syncoid keypair on a cadence.
- **No CVE/vulnerability scanning in CI.** `.github/workflows/ci.yml` builds
  and boot-tests every host but doesn't check the resulting closures against
  known nixpkgs CVEs (e.g. `vulnix`).
- **No unattended `nix flake update` cadence.** Updates are fully manual today
  (see the earlier discussion in this session: recommended a scheduled
  `flake update` + build/check → PR-for-review, manual deploy — NOT full
  auto-deploy, given no rollback-on-failure exists yet).
- **No disk/hardware health monitoring.** No `smartd`/SMART checks on
  europa's NAS disks, no UPS/power monitoring (no `nut`/`apcupsd` anywhere).
- **No SSH/login hardening beyond NixOS defaults.** `services.openssh.enable`
  is set (`modules/common.nix`) with no `PermitRootLogin` override, no
  fail2ban/sshguard, no 2FA/U2F/WebAuthn on any host.
- **No TLS/cert-expiry monitoring** independent of Cloudflare's own handling
  (only `cloudflare_cert` exists for the tunnel credential, not an ACME/cert
  pipeline to watch).

None of these are urgent for a single-operator home lab — flag as candidates
to prioritize if europa's data footprint grows, if a second operator joins,
or after the callisto server-consolidation move (Future direction, above)
changes the blast radius of a bad deploy.

### Validation still required (no nix/KVM in the authoring env)

- `nix flake lock` to lock the new `home-manager` input (CI auto-locks but the
  committed lock is stale).
- `nix flake check` + the `build`/`boot-test` CI jobs to shake out eval errors —
  nothing here was evaluated locally.
- `make gen-secrets` to populate the generated service credentials + syncoid
  keypair (and commit `secrets/syncoid_ed25519.pub`).
- Real-hardware provisioning: REPLACE-ME disks + the callisto NIC name + LUN
  `mkfs`/labels.
