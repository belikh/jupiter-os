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
   both `terraform/unifi` and `modules/services/dns.nix` (pending a check that
   terranix can import it cleanly).
4. **CI VM smoke tests** — boot each host in QEMU and assert multi-user.
5. **Backup topology** — syncoid replication to the NAS; drop direct-B2.
6. **elitedesk services** — DB + Loki + syslog receiver consuming the iSCSI
   LUNs and the Wyze syslog target.
7. **home-manager + roaming** — adopt home-manager for `io`; scaffold the
   future desktop host slots; Syncthing-synced `$HOME` across personal
   machines.

Plus a **docs trim** folded into the relevant PRs (cut the line-level tables).

### Already landed

- Inheritance tidy (commit on this branch): base CLI tooling →
  `common.nix`; `sops.defaultSopsFile`; branding opt-in; dropped unused
  `docker` group; headscale → lenovo only.
- Stage 1 — storage profiles: new `modules/storage/zfs-profiles.nix`
  (`jupiter.storage.profile` = impermanent/stateful/minimal/none) replacing
  `zfs-impermanent.nix` and the per-host `disko.nix` on `lenovo`/`dashboards`;
  `lenovo` → stateful, `dashboards` → impermanent (kiosk persist), `t460s` →
  impermanent; `nas` stays bespoke; REPLACE-ME assertion. `impermanence.nix`
  gained `persistAdminHome`/`extraDirectories`/`extraFiles`/`users`.
</content>
</invoke>
