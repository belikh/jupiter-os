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

## Ephemeral BinaryLane build server ("rebuild the world")

**Goal:** CI runs `check` (fmt + `nix flake check`) and `build-and-boot-test`
as it does today; once those pass on `master`, a disposable BinaryLane VPS is
launched, rebuilds every fleet host's closure — each tuned for that host's
own CPU rather than nixpkgs' portable baseline — pushes the results to an
attic binary cache, then destroys itself. Every host then just pulls
pre-built, CPU-tuned closures from attic instead of building or substituting
from `cache.nixos.org` locally. Launch it only when there's something to
build, keep it running only as long as the build takes, and never leave it
running idle — this is a cost control, not a permanent server.

**Why not just keep building on `cache.nixos.org` substitutes:** the fleet's
hosts have known, differing CPUs (e.g. the TCx Wave kiosks are a confirmed
Skylake-U i5-6300U — see `modules/services/tcxwave-power-tuning.nix`), and
`cache.nixos.org` can only ever serve the generic portable baseline. Building
once per commit, tuned per host, on a beefy short-lived VPS is cheaper and
faster than every host locally compiling its own optimized closure (or
running untuned forever).

**Trigger model:** the roadmap goal above (launch on every green CI run on
`master`) is confirmed as the real design, not a weekly cron — commits to
this repo are already infrequent (roughly weekly, more often when adding
software/config), so "every green run" and "roughly weekly" are the same
thing in practice. `make rebuild-world` also exists for an on-demand run
without waiting on CI.

### What's landed

- **`hosts/pallene/configuration.nix`** — the minimal NixOS config the
  BinaryLane build server boots. Not a fleet member: no storage profile, no
  backup, no branding, no desktop, absent from `ci.yml`'s
  `build-and-boot-test` matrix and from `deploy.nodes`. Named after a small,
  distant Jovian moon — fitting for a host that's only ever briefly in orbit.
- **`modules/services/build-server.nix`** (`jupiter.services.buildServer`) —
  the automated workflow that runs unattended once pallene boots: clone the
  repo at a given ref, `nix build` each host in `hosts` one at a time
  (best-effort — one broken host doesn't stop the rest), `attic push` each
  successful result, then look itself up via the BinaryLane API by hostname
  and `DELETE` itself. The self-destruct runs from a shell `trap on EXIT`, so
  it fires on success, on a build failure, and on a script bug alike — never
  just the happy path. A completely independent systemd timer force-destroys
  the server after 4h regardless, in case the main run hangs outright.
  `atticServer` points at `https://attic.jupiter.au` — reached over the
  public internet via the Cloudflare Tunnel, since pallene has no route to
  the home LAN otherwise.
- **`modules/core/build-tuning.nix`** (`jupiter.build.microarch`) — per-host
  option wiring `nixpkgs.hostPlatform.gcc.arch`/`.tune` to that host's actual
  CPU. Defaults to `null` (today's portable baseline). Set on every host
  whose real CPU is now confirmed: `"skylake"` on the 4 kiosks and `himalia`
  (all Skylake-U — i5-6300U / i5-6200U respectively), `"btver2"` on `europa`
  (HPE MicroServer Gen10, AMD Opteron X3216 — a Puma-core "Cato" APU,
  ISA-equivalent to Jaguar). Left `null` everywhere else until hardware is
  confirmed.
- **`modules/services/attic-server.nix`** (`jupiter.services.attic`) — runs
  `services.atticd` on `europa`, storage on `tank/services/attic` (bulk,
  reproducible — deliberately outside the offsite restic set), token auth via
  a `make gen-secrets`-generated RS256 key (`attic_server_token_secret`).
  Exposed at `attic.jupiter.au` through the existing Cloudflare Tunnel
  (`lib/site.nix`'s `tunnel.ingress`) rather than only on the home LAN, since
  both pallene and roaming `himalia` need to reach it from outside the house.
- **Fleet substituters** (`modules/common.nix`) — every host that imports
  `common.nix` lists `https://attic.jupiter.au/jupiter-os` ahead of
  `cache.nixos.org`. The paired `trusted-public-keys` entry is a
  `REPLACE-ME` placeholder (see Open questions) — until it's replaced with
  the cache's real key, Nix just silently skips this substituter, so it's
  safe to ship as-is.
- **Cloudflare R2 for ISO hosting** (`terraform/cloudflare/default.nix`'s
  `cloudflare_r2_bucket.pallene_iso`, `scripts/upload-pallene-iso-r2.sh`) —
  chosen over Backblaze B2 because this account doesn't actually have a B2
  bucket — despite `restic_env`/`restic_password` already existing as sops
  keys, nothing real has been deployed to a B2 account yet (this whole repo
  is pre-deployment; see the fleet-wide `REPLACE-ME` disk placeholders). R2
  slots into the terraform/cloudflare stack that already exists for the
  tunnel/DNS. The upload script pushes the built ISO via R2's
  S3-compatible API and hands back a presigned URL (bucket stays private) —
  `make rebuild-world` wires it into `scripts/binarylane-build-server.sh`'s
  `ISO_URL`.
- **`scripts/binarylane-build-server.sh`** — the CI-side driver against the
  actual BinaryLane API (openapi spec `binarylane.com.au`, v0.39.0): resolves
  the Melbourne region and the cheapest `>=8vcpu/16GB/300GB` size slug
  dynamically against the live account (`GET /v2/regions`, `/v2/sizes`) —
  matches the "CPU Optimised" 8-thread/16GB/300-600GB tier, ~AUD $144/mo —
  rather than hardcoding slugs BinaryLane could renumber. Then: create a
  placeholder server, `POST .../backups` to upload the pallene ISO from the
  R2 presigned URL as a backup image (BinaryLane has no "create server
  booting a custom ISO" endpoint — only `AttachBackup` on an *existing*
  server, whose description explicitly calls out ISO-boot as a supported
  use), attach it, reboot into it, then poll `GET /v2/servers/{id}` until it
  404s (self-destructed) or force-destroy after a timeout.
- **`make pallene-iso`** / **`make rebuild-world`** — build the ISO with the
  BinaryLane API token + attic push token baked in (materialized from sops
  immediately before the build, deleted immediately after — same pattern as
  `make build-mx4300`'s OpenWrt secret injection), upload it to R2, then
  drive one full run.

### Open questions / not yet real

- **BinaryLane API token**: the user has a real token ready to hand over for
  testing — add it to `secrets/secrets.yaml` as `binarylane_api_token`
  directly via `sops secrets/secrets.yaml` (not pasted into chat/logs) so it
  never sits in plaintext anywhere but the encrypted file.
- **R2 credentials**: `cloudflare_account_id`, `r2_access_key_id`,
  `r2_secret_access_key` need adding to `secrets/secrets.yaml` by hand
  (external-account creds, like `cloudflare_api_token` — never auto-generated
  by `gen-secrets.sh`). The R2 API token needs Object Read & Write scope on
  the `jupiter-os-pallene-iso` bucket.
- **`attic cache create jupiter-os` hasn't been run yet** — once
  `jupiter.services.attic` is actually deployed to europa, create the cache,
  retrieve its real public key (`attic cache info jupiter-os`), and replace
  the `REPLACE-ME` placeholder in `modules/common.nix`'s
  `trusted-public-keys`.
- **`attic_push_token` doesn't exist yet** — it's a JWT that has to be minted
  with `atticadm make-token` against the real, running atticd instance (see
  docs/07-secrets-management.md's "third category" note), so it can't be
  generated ahead of that server existing. One-time manual step once atticd
  is deployed.
- **BinaryLane's cloud-init datasource on a custom-booted ISO is unverified**
  — `modules/services/build-server.nix` reads the target git ref from
  `/var/lib/cloud/instance/user-data.txt` so one ISO build can be reused
  across commits, but this assumes BinaryLane exposes cloud-init user-data to
  a raw ISO boot the same way it does for their own catalog images. Decision:
  test this once for real against an actual BinaryLane boot before relying on
  it in CI; fall back to baking the ref into the ISO at build time if it
  doesn't work.
- **CPU-microarch tuning risk**: targeting a host's real `-march` only
  changes what gets *built*, and a package whose own test suite (`checkPhase`)
  executes target-tuned code — not just compiles it — will fail loudly on
  the build server if its CPU doesn't support those instructions. That's a
  wasted build, not a silently-broken host, but it means "rebuild the world"
  isn't unattended-safe for `europa`'s `btver2` target (untested combination)
  until exercised once for real. `ganymede`/`callisto`/dashboards beyond the
  4 confirmed kiosks stay `null` (portable baseline) until their hardware is
  confirmed too.

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
- **Generated `jupiter.*` options reference** — audited every `jupiter.*`
  option across `modules/`; the handful missing a `description` (nested
  submodule options in `impermanence.nix`, `loki.nix`, `n8n.nix`,
  `replication.nix`) now have one. `lib/module-options.nix` evaluates a
  synthetic host importing every option-declaring module (plus the same
  flake-injected modules `mkHost` gives real hosts, so unconditional `config`
  blocks resolve) and feeds `options.jupiter` to `pkgs.nixosOptionsDoc`, whose
  `nixos-render-docs`-backed `optionsCommonMark` becomes `docs/module-options.md`.
  `make docs-modules` regenerates it; `make docs-modules-check` (wired into the
  CI `check` job) fails if it's stale. `docs/04-modules-reference.md` keeps its
  hand-written per-module prose but now points at the generated file for exact
  type/default/description — no more transcribing options by hand. Verified
  with `make fmt` + `nix flake check` (only the pre-existing `REPLACE-ME`
  disk-placeholder assertions remain).

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
- ~~**No post-deploy health check / automated rollback.**~~ **Closed
  (deploy-time only):** `deployActivate` in `flake.nix` wraps every host's
  deploy-rs activation with a post-`switch-to-configuration switch` health
  check (`systemctl is-system-running` must reach `running`/`degraded` within
  120s); a non-zero exit is treated by deploy-rs as a failed activation and
  triggers `autoRollback` to the previous generation (on by default, as is
  `magicRollback`'s SSH-reconnect confirmation). This covers the case an
  unattended `deploy` creates. It does **not** cover a *later*, unrelated
  physical/manual reboot failing to reach multi-user — that needs
  bootloader-level boot-counting (systemd-boot doesn't do this out of the box
  the way GRUB's fallback does) and was explicitly scoped out as a separate,
  harder problem needing real-hardware validation.
- **No backup-restore verification.** Syncoid replication + sanoid snapshots +
  restic offsite all exist, but nothing periodically proves a snapshot is
  actually restorable (vs. just "the send/recv succeeded").
- **No secrets rotation.** `make gen-secrets` (`scripts/gen-secrets.sh`) fills
  in missing service-to-service credentials once; nothing rotates the
  sops-nix age keys or the generated passwords/syncoid keypair on a cadence.
- **No CVE/vulnerability scanning in CI.** `.github/workflows/ci.yml` builds
  and boot-tests every host but doesn't check the resulting closures against
  known nixpkgs CVEs (e.g. `vulnix`).
- ~~**No unattended `nix flake update` cadence.**~~ **Closed, including
  auto-deploy:** `.github/workflows/flake-update.yml` runs weekly (Mondays
  06:00 UTC, `workflow_dispatch` too). `update` job: `nix flake update`,
  validated through the same gates as regular CI (fmt, `nix flake check`,
  build every host, boot-smoke every VM-bootable host); if `flake.lock`
  changed and everything passed, it's committed straight to `master` — no PR
  gate, by deliberate choice (all the same checks already ran on that exact
  lockfile). `deploy` job: on that push, deploys every host over the
  headscale mesh (`tailscale/github-action` joins as an ephemeral node, then
  `deploy .#<host> --hostname <host>.home.jupiter.au`), relying on
  `deployActivate`'s rollback (previous gap) to make an unattended deploy
  safe. Needs two hand-provisioned repo secrets before it does anything real
  — `HEADSCALE_PREAUTH_KEY` (from `headscale preauthkeys create` on
  ganymede) and `DEPLOY_SSH_PRIVATE_KEY` (whose public half must be
  authorized for the deploy user on every host) — see the workflow file's
  header comment. Not yet exercised against real hardware (see "Validation
  still required" below — the whole repo is pre-deployment).
- **No UPS/power monitoring** (no `nut`/`apcupsd` anywhere). ~~No disk/
  hardware health monitoring.~~ **Partially closed:** `jupiter.storage.smartMonitoring`
  (`modules/storage/smart-monitoring.nix`) runs smartd on europa — autodetects
  attached disks, schedules short/long self-tests, `wall` + journal `LOG_CRIT`
  on failure. No paging yet (still needs the broader alerting stack below).
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
- `.github/workflows/flake-update.yml`'s `deploy` job needs
  `HEADSCALE_PREAUTH_KEY` + `DEPLOY_SSH_PRIVATE_KEY` repo secrets provisioned
  by hand before it can do anything (headscale itself isn't live yet either —
  chicken-and-egg with the rest of pre-deployment). Also unverified: whether
  `systemctl is-system-running` reliably lands on `running`/`degraded` (not
  stuck `starting`) within the 120s health-check window on real hardware for
  every host, especially europa (iSCSI/NFS mounts) and callisto (netboot).

## NixOS Configuration Tech Debt & Hardening

Generated from the static audit in `NIX_AUDIT_REPORT.md` (2026-07-01, score
85/100). Most items below overlap with "Operational maturity gaps" above —
that section is the narrative context; these are the trackable tasks.

### [HIGH PRIORITY]

- [x] **CI was red on master** (discovered 2026-07-01) — **fixed**, two
      distinct causes:
      1. The `jupiter.storage.disk` REPLACE-ME assertion
         (`modules/storage/zfs-profiles.nix`) fired for *every* disk host
         (`ganymede`, `metis`, `adrastea`, `amalthea`, `thebe`, and now
         `elara`/`carme`) unconditionally at eval time, failing
         `system.build.toplevel` itself rather than just a real disko install.
         Since no host in the fleet has real hardware yet, this blocked CI
         permanently rather than protecting anything (the placeholder path
         doesn't exist, so disko would just fail loudly on its own if actually
         run against it) — turned into a non-blocking `warnings` entry instead
         of a hard `assertions` entry.
      2. Once (1) was fixed, the *same* eval error `callisto` was hitting
         turned out to also affect every other disk/impermanent host: the
         fleet-wide CachyOS kernel (`linuxPackages_cachyos`, currently 7.1.x)
         is newer than zfs's declared `kernelMaxSupportedMajorMinor` (7.0), so
         nixpkgs refuses to evaluate the zfs kernel module as `broken`. Fixed
         by pinning `boot.kernelPackages = pkgs.linuxPackages_7_0` (mkForce)
         inside the `zfs-profiles.nix` mkIf block — covers every host with a
         storage profile, including overriding the TCx Wave kiosks'
         power-tuning `linuxPackages_latest` pick — plus the same pin on
         `europa` (bespoke NAS config, not gated by that module). `callisto`
         itself doesn't need zfs at all (diskless, state lives on europa over
         iSCSI/NFS), so it instead gets
         `boot.supportedFilesystems.zfs = lib.mkForce false` to stop
         `nixos/modules/profiles/base.nix`'s fleet-wide zfs-on-by-default from
         pulling the module in unnecessarily. Bump the `linuxPackages_7_0` pin
         in lockstep whenever nixpkgs raises zfs's max-supported kernel.
      3. Once (1) and (2) were fixed, `ganymede` hit a pre-existing sops-nix
         eval error: `sops.secrets.pg_n8n_password.owner = "n8n"` required a
         static `users.users.n8n`, but n8n's NixOS module runs under
         `DynamicUser = true` and never creates one. Dropped the `.owner`
         override — n8n gets the password via an `_FILE`-suffixed env var,
         which its module already routes through systemd's `LoadCredential`
         (root reads the sops-nix default-permission secret at service start,
         no static user needed).
      4. With `build` finally passing for (almost) every host, `boot-test`
         surfaced a real, previously-never-exercised bug (CI had never gotten
         this far before): `modules/common.nix`'s `vmVariant` forced legacy
         BIOS GRUB (`efiSupport = false; device = "/dev/vda"`), but every
         disko layout here uses a GPT `EF00` UEFI System Partition with no
         BIOS boot partition — so every VM hung right after printing "Welcome
         to GRUB!", unable to find a place to embed/read GRUB's second stage.
         Fixed by setting `virtualisation.useEFIBoot = true` instead (matches
         real hardware) and giving `zfs-profiles.nix` its own
         `efiSupport`/`device` defaults tied to the ESP it creates (also fixes
         a latent real-hardware gap: the TCx Wave kiosks had *no* bootloader
         config at all beyond NixOS's non-functional bare default). Also found
         `boot.loader.timeout` was unset fleet-wide, which systemd-boot treats
         as `"menu-force"` — wait forever for a keypress, never auto-boot —
         a real risk on any headless/remote reboot with nobody at the
         console; added a fleet-wide `boot.loader.timeout = 3` default
         (`modules/common.nix`). Finally, `scripts/boot-smoke.sh`'s "reached
         multi-user" detection was unreliable in this exact setup — systemd's
         own status line doesn't reliably reach the serial console once
         `console=ttyS0` is added for the vmVariant's bootloader-controlled
         boot path (needed since `$QEMU_KERNEL_PARAMS` only applies to
         qemu-vm.nix's *direct*-kernel-boot mode, not the bootloader path) —
         so the detection now also matches the `<host> login:` prompt, direct
         proof multi-user was reached. Verified locally end-to-end on `metis`
         (reaches a real login prompt); also restructured `ci.yml` into one
         `build-and-boot-test` job per host (build, then boot-test only
         `if: success()`, skipped for `callisto`) instead of two separate
         matrices, so a broken build no longer burns a second runner on a
         boot-test we already know will fail.
- [ ] Add SSH/login hardening: `fail2ban` or `sshguard`, explicit
      `services.openssh.settings.PermitRootLogin = "no"`, consider
      U2F/WebAuthn for the `io` account (`modules/common.nix`).
- [x] Replace the duplicate literal `hashedPassword` shared by
      `users.users.io` and `users.users.root` in the `virtualisation.vmVariant`
      block — **done**: it's in `modules/common.nix` (not
      `hosts/ganymede/configuration.nix` as the audit's line ref said; that
      block is shared by every host's VM variant, not ganymede-specific).
      Added a comment explaining the sharing is intentional — the block only
      ever runs as an ephemeral local `make test-<host>` QEMU VM, never
      deployed, so a second hardcoded hash would add no real security value.
- [ ] Add a secrets-rotation cadence for sops-nix age keys and
      `make gen-secrets`-generated passwords/syncoid keypair (currently
      generated once, never rotated).
- [ ] Add CVE/vulnerability scanning to CI (e.g. `vulnix`) so host closures
      are checked against known nixpkgs advisories, not just built/boot-tested.
- [x] Register `hosts/elara/` and `hosts/carme/` in `flake.nix`
      `nixosConfigurations` — **done**, added to the `build`/`boot-test` CI
      matrices too. Gave both a real random `networking.hostId` (that's just a
      format requirement, not tied to real hardware — no reason to leave it
      `REPLACE-ME`). Their disk is still `REPLACE-ME`, which is now just a
      build-time warning (see the CI fix note above), not a CI failure.
- [ ] Prove the deploy/rollback and unattended flake-update path against
      real hardware once provisioned — `flake.lock`'s `home-manager` input
      pin, `HEADSCALE_PREAUTH_KEY`/`DEPLOY_SSH_PRIVATE_KEY`, and the
      120s `systemctl is-system-running` health-check window are all
      currently unverified outside CI/QEMU (tracked under "Validation still
      required" above; listed here so it isn't lost as a discrete task).

### [MEDIUM PRIORITY]

- [ ] Split `modules/gaming/console.nix` (398 lines) and
      `modules/desktop/dashboard-gaming.nix` (302 lines) into focused
      sub-modules (kernel/session/gaming concerns) for readability.
- [ ] Factor `flake.nix`'s orchestration logic (`mkHost`, `deployActivate`
      wrapping, `backupHubModule` derivation) out into `lib/` helpers so the
      flake entry point stays a thin, skimmable declaration.
- [ ] Wire real `checks` into `flake.nix` (`flake.nix:318` currently only
      exposes `deploy-rs`'s `deployChecks`) so `make check`/`nix flake check`
      locally exercises what CI's boot-smoke job actually gates on, instead
      of giving a false sense of completeness.
- [ ] Add a metrics/alerting stack (Prometheus/Grafana/Alertmanager or a
      lighter ntfy/healthchecks.io hook) — Loki today covers logs only, so
      outages are discovered by using the affected service, not by
      notification.
- [ ] Add a periodic backup-restore verification job — syncoid/sanoid/restic
      all exist, but nothing proves a snapshot is actually restorable versus
      "the send/recv succeeded."
- [ ] Add TLS/cert-expiry monitoring independent of Cloudflare's own tunnel
      handling (no ACME/cert pipeline is currently watched).
- [ ] Convert `modules/services/tcxwave-power-tuning.nix:160`'s
      `services.journald.extraConfig` raw string block to structured
      `services.journald.settings` attrs where the option surface allows it.

### [LOW PRIORITY]

- [ ] Add UPS/power monitoring (`nut`/`apcupsd`) — currently absent fleet-wide.
- [ ] Consider explicit security-hardening `boot.kernel.sysctl` entries
      (e.g. `kernel.kptr_restrict`, `kernel.yama.ptrace_scope`,
      `net.ipv4.conf.all.rp_filter`) or a documented decision to accept the
      current trusted-LAN threat model without them.
