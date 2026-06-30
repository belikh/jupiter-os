# Roadmap & structural decisions

Working notes for the structure review started on the
`claude/project-structure-review-txkwlb` branch. Captures the decisions taken
so they survive across sessions. This is a planning doc, not reference docs —
it should shrink as items land and the decisions fold into the real docs.

## Guiding principles (decided)

- **`jupiter.*` toggles everywhere.** Every host configures storage,
  impermanence, desktop, etc. through the `jupiter.*` option namespace — no
  hand-rolled per-host config where a toggle fits. (Today only `t460s` does
  this; the others predate it.)
- **NAS is the data hub.** All host state lands on the NAS first; the NAS is
  the *single* offsite egress point (restic → Backblaze B2). No host backs up
  directly offsite.
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
| `impermanent` | rolls back to `@blank` each boot | `local/root`, `local/nix`, `safe/persist` | `t460s`, `dashboards` |
| `stateful` | persistent root | `root`, `nix`, `var` | `lenovo` |
| `minimal` | persistent root | `root`, `nix` | (simple disk hosts) |

- **lenovo:** `stateful` — n8n flows + libvirt images persist on a dedicated
  `/var`; no rollback. (Binaries are in `/nix` and always persist regardless.)
- **dashboards:** `impermanent`, persist set = **minimal + the kiosk user's
  Chromium profile** (machine-id, SSH host key, sops-nix, `/var/log`, Chromium
  profile).
- **nas:** stays **fully bespoke** — its `disko.nix` keeps the rpool +
  zvols + `netboot`/`scratch` layout; `tank`/`europa` remain hand-created and
  imported via `boot.zfs.extraPools`. The shared module is for the simpler
  hosts.
- `REPLACE-ME` device paths stay unset but get a **friendly assertion**
  pointing at the install runbook instead of a raw eval failure.

## Backups (decided)

- **Mechanism:** `syncoid` (ZFS send/recv over SSH), NAS pulls.
- **Source → dest:** server state datasets (e.g. `lenovo:/var`) →
  `tank/backups/<host>` on the NAS.
- **Frequency:** hourly.
- **Offsite:** `tank/backups` is already in the sanoid `important` policy and
  the restic offsite path, so replicated state inherits snapshots + offsite.
- **Remove** lenovo's direct-to-B2 restic config — NAS is the sole egress.

## Roaming desktop (decided direction)

Goal: sit at any personal machine (home, eventually the parents' house) and
log in as if on the home PC.

- **Adopt home-manager** — user `io`'s dotfiles/packages/desktop config managed
  declaratively in the flake, identical across personal machines by rebuild.
- **Portable `$HOME`:** local home on each machine, **Syncthing** mirrors the
  data dirs via the NAS hub. Offline-tolerant — important for the parents-house
  node over the headscale mesh. (Config is declarative via home-manager; only
  data is synced.)
- **Identical `niri`** on every personal machine.
- **Hosts in scope:** `t460s` (now), a **home desktop PC** (future slot), a
  **parents-house PC** (future slot, joins over the mesh). Kiosks are
  appliances by default (dashboard mode) but can present a personal session on
  a VT — they already have the dual-VT dashboard/gaming switch
  (`modules/desktop/dashboard-gaming.nix`); a personal/desktop "mode" fits the
  same pattern.

## Future direction: consolidate servers onto elitedesk

The longer-term intent is to **move all server roles onto `elitedesk` and
retire `lenovo`** (repurposed elsewhere). The Postgres-on-elitedesk +
HA/n8n-as-LAN-consumers wiring is a step in that direction, but it currently
creates a cross-host dependency (lenovo's n8n needs elitedesk's Postgres, which
needs the NAS iSCSI). When the migration happens, n8n / HA / DNS / headscale /
cloudflared / the HA VM move to elitedesk and these become local connections.
Not started — it's a large move that needs its own plan (and elitedesk is
diskless/netboot today, so its role/boot story changes).

## Out of scope / deferred

- **Containers** — none wanted for now (libvirt VMs + n8n cover it).
- **NAS LACP bond** — stays disabled until the UniFi switch-side LACP exists.
- **cloudflare_api_token** — user adds it to `secrets.yaml` when needed.

## Staged PRs

1. ~~**Storage/disko** — parameterized `jupiter.storage` module (profiles),
   full toggle adoption on lenovo/dashboards (nas stays bespoke), kiosk
   impermanence, friendly device-path assertion.~~ **Done** (see below).
2. **Module reshuffle + style** — normalize `modules/` into category subdirs;
   standardize one module idiom (explicit `lib.*`, consistent arg order);
   document the convention in `CLAUDE.md`.
3. **Network single source of truth** — shared VLAN/subnet attrset consumed by
   both `terraform/unifi` and `modules/network/dns.nix` (pending a check that
   terranix can import it cleanly).
4. **CI VM smoke tests** — boot each host in QEMU and assert multi-user.
5. **Backup topology** — syncoid replication to the NAS; drop direct-B2.
6. **elitedesk services** — DB + Loki + syslog receiver consuming the iSCSI
   LUNs and the Wyze syslog target.
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
  module-style convention documented in `CLAUDE.md` (existing `with lib;`
  conversion deferred to run with nix eval).
- **Stage 3 — network SoT** — `lib/site.nix` shared by `terraform/unifi` and
  `jupiter.dns`.
- **Stage 4 — CI boot tests** — `scripts/boot-smoke.sh` + `boot-test` CI job;
  rollback service guarded for VM builds.
- **Stage 5 — backup topology** — `modules/storage/replication.nix` (syncoid),
  NAS pulls `lenovo:rpool/var` hourly; lenovo direct-B2 dropped.
- **Stage 6 — elitedesk services** — `postgresql.nix` + `loki.nix` on the iSCSI
  LUNs; static identity (10.1.1.21) for the syslog target.
- **Stage 7 — home-manager + roaming** — `modules/home/` (`jupiter.home.enable`),
  home-manager input + injection, niri config for `io`; `desktop`/
  `parents-desktop` scaffolds (unregistered).
- **Postgres consumers** — `jupiter.services.postgresql.databases` (networked
  roles + sops passwords + scram-sha-256); elitedesk serves `homeassistant`
  (HA VM) and `n8n` (lenovo). n8n migrated off SQLite. HA recorder `db_url` is
  set inside the HAOS VM (not NixOS-managed). Passwords are generated by
  `make gen-secrets` (not hand-set); still needs a one-time n8n SQLite→PG data
  migration.
- **Auto-wired central backup** — `jupiter.backup` (`modules/storage/backup.nix`),
  defaulted on by the `stateful` storage profile; `flake.nix`'s `backupHubModule`
  derives the NAS's syncoid sources from the fleet, and the NAS backs up
  `tank/backups` wholesale. New state-holding hosts replicate offsite with no NAS
  edit. Source-side pull key auto-authorized from `site.backupHub`.
- **Generated service credentials** — `make gen-secrets` (`scripts/gen-secrets.sh`)
  produces random, impossible machine-to-machine passwords + the syncoid keypair
  straight into sops; no inter-service password is ever hand-set. Public syncoid
  key committed at `secrets/syncoid_ed25519.pub`, read by `lib/site.nix`.

## ~~Known gap: elitedesk DB/Loki data offsite~~ — CLOSED

elitedesk's Postgres + Loki live on raw iSCSI zvols that restic can't walk, so
`modules/services/state-backup.nix` (`jupiter.services.stateBackup`) now runs an
hourly `pg_dumpall` + a Loki `rsync` into an NFS mount of
`nas:/tank/backups/elitedesk`. That lands under `tank/backups`, so it inherits
the `important` sanoid policy and the wholesale restic offsite path — the live
data stays on the fast SSD zvols while a consistent, restorable copy is
snapshotted + shipped offsite. One-time: `zfs create tank/backups/elitedesk`.

### Validation still required (no nix/KVM in the authoring env)

- `nix flake lock` to lock the new `home-manager` input (CI auto-locks but the
  committed lock is stale).
- `nix flake check` + the `build`/`boot-test` CI jobs to shake out eval errors —
  nothing here was evaluated locally.
- `with lib;` → explicit conversion of the 11 older modules.
- `make gen-secrets` to populate the generated service credentials + syncoid
  keypair (and commit `secrets/syncoid_ed25519.pub`).
- Real-hardware provisioning: REPLACE-ME disks + the elitedesk NIC name + LUN
  `mkfs`/labels.
