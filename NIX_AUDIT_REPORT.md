# NixOS Configuration Audit — jupiter-os

Static analysis of the `jupiter-os` flake as of 2026-07-01 (commit `9f6b478`).
Scope: all `.nix` files under `flake.nix`, `hosts/`, `modules/`, `terraform/`,
`packages/`, plus `secrets/secrets.yaml` and CI workflows referenced by the repo.

## Scoring Summary

| Category | Score | Max |
|---|---|---|
| Architecture & Maintainability | 27 | 30 |
| Reproducibility & Supply Chain | 18 | 20 |
| Configuration Depth & Coverage | 16 | 20 |
| Security & Hardening | 11 | 15 |
| Ergonomics & Maintenance | 13 | 15 |
| **Total** | **85** | **100** |

---

## 1. Architecture & Maintainability — 27/30

### Strengths
- Clean category-based module layout (`modules/{core,desktop,gaming,storage,network,services}/`)
  gated behind a consistent `jupiter.*` option namespace, with hosts opting in
  via toggles rather than inlining config (`hosts/himalia/configuration.nix`
  is a good example of a thin host file).
- The `with lib;` anti-pattern is essentially eliminated — only two remaining
  hits (`packages/share-tech-mono/default.nix:24`,
  `packages/share-tech-mono/console.nix:49`), both scoped to a package's
  `meta = with lib; { ... }` block, which is idiomatic nixpkgs style rather
  than the module-wide `with lib;` anti-pattern this rubric penalizes.
- Consistent module skeleton (`options.jupiter.<x>` → `let cfg = ...` →
  `config = lib.mkIf cfg.enable { ... }`) applied uniformly, including in
  recently-converted modules (branding, desktop/default, dashboard-gaming,
  impermanence, iscsi, nas-bond, pxe-server, dns, bazzite, mqtt, syncthing —
  per `docs/roadmap.md`'s Stage 2 notes).
- Good separation of system vs. user config: `modules/home/` is a distinct,
  opt-in (`jupiter.home.enable`) layer for the `io` user's dotfiles/niri,
  kept separate from system modules; data roams via Syncthing rather than
  being baked into home-manager.
- Network facts centralized in `lib/site.nix` as plain data, imported by both
  `modules/network/dns.nix` and `terraform/unifi/default.nix` — no
  CIDR/hostname duplication between the NixOS and Terraform layers.
- File sizes are reasonable overall (4,925 total lines across 51 files,
  average ~97 lines/file); the four kiosk host files
  (`hosts/{metis,adrastea,amalthea,thebe}/configuration.nix`) are near-identical
  by design (one host per physical room dashboard) rather than duplicated
  through neglect.

### Deficiencies & Anti-patterns
- `modules/gaming/console.nix` (398 lines) and
  `modules/desktop/dashboard-gaming.nix` (302 lines) are large, multi-concern
  modules (kernel tuning, PAM, polkit, session switching, gamescope wiring all
  in one file) — candidates to split into sub-modules (e.g.
  `bazzite/{kernel,session,gaming}.nix`) for readability.
- `flake.nix` itself is 328 lines and carries orchestration logic
  (`mkHost`, `deployActivate` wrapping, `backupHubModule` derivation) that
  could be factored into `lib/` helpers to keep the entry point declarative
  and skimmable.
- `hosts/elara/configuration.nix` and `hosts/carme/configuration.nix` are
  scaffolds not yet registered in `flake.nix` `nixosConfigurations` — living,
  half-wired host files increase the risk of silent drift if a shared module
  changes shape and nobody rebuilds them to check.
- No per-module README/comment documenting the `jupiter.<x>` option surface
  at a glance — option semantics must be read out of each module's
  `options.jupiter.*` block directly (mitigated somewhat by
  `docs/04-modules-reference.md`, but that's an external doc rather than
  in-repo option `description`s that could back it via `nixos-render-docs`).

---

## 2. Reproducibility & Supply Chain — 18/20

### Strengths
- Fully flake-based; `flake.lock` is present and committed (13KB, single
  lockfile governs `nixpkgs`, `chaotic`, `home-manager`, `sops-nix`,
  `disko`, `deploy-rs`, etc.).
- Deliberate avoidance of a separate `jovian` flake input — consumed via
  `inherit (chaotic.vendored) jovian;` specifically to prevent the
  hash-mismatch class of drift documented in `CLAUDE.md`'s Gotchas section.
  This is a notably mature supply-chain decision most home-lab flakes miss.
- `mkHost` injects flake modules (sops, impermanence, disko, home-manager,
  jovian, chaotic) via a lexical closure rather than `specialArgs`, keeping
  the module graph's dependency surface explicit and avoiding the common
  `specialArgs`-leaks-everywhere anti-pattern.
- CI (`.github/workflows/ci.yml`) builds every host closure and boot-tests
  in QEMU (`scripts/boot-smoke.sh`); a separate weekly
  `.github/workflows/flake-update.yml` runs `nix flake update` behind the
  same gates before auto-committing — an unusually disciplined update
  cadence for a personal-scale repo.
- `formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-rfc-style;`
  is wired in `flake.nix:321`, and both `make fmt` and `make fmt-check` use
  it, so formatting is enforceable in CI, not just aspirational.
- No impure builtins (`builtins.getEnv`, `builtins.currentSystem` misuse,
  network fetches during eval) detected in module/host evaluation paths —
  sops secrets are correctly deferred to activation time rather than
  evaluated at build time (`CLAUDE.md` Gotchas confirms this is a known,
  intentional boundary).

### Deficiencies & Anti-patterns
- `nix flake check`'s `checks` output (`flake.nix:318`) only wires
  `deploy-rs`'s `deployChecks` — there are no `pkgs.testers`/NixOS VM test
  `checks` beyond the separate boot-smoke CI script, so `nix flake check`
  alone (as `make check` runs it) doesn't exercise the boot-smoke path
  locally; a contributor running `make check` before pushing gets a false
  sense of completeness relative to what CI actually gates on.
- Two unregistered host scaffolds (`hosts/elara/`, `hosts/carme/`) are present
  in the tree but excluded from `nixosConfigurations` — they don't get
  built or checked by CI at all, so they can silently rot until someone
  tries to register them.
- `docs/roadmap.md`'s "Validation still required" section flags that the
  committed `flake.lock` is stale relative to the new `home-manager` input
  and that nothing here has been evaluated against real hardware — a
  reproducibility gap in practice, not in principle (the mechanism is sound,
  but the lockfile-to-code correspondence hasn't been proven).

---

## 3. Configuration Depth & Coverage — 16/20

### Strengths
- Real declarative service coverage via official NixOS module options
  throughout: `services.postgresql`, `services.loki`, `services.syncthing`,
  `services.headscale`, `services.sops`, `services.smartd`
  (`modules/storage/smart-monitoring.nix`), rather than raw
  `systemd.services.foo.script` string blobs for things that have first-class
  options.
- `home-manager` is adopted for the roaming user environment
  (`modules/home/io.nix`, `modules/home/default.nix`, gated by
  `jupiter.home.enable`), covering dotfiles/niri config — the repo explicitly
  tracks this as a "Landed" roadmap stage rather than leaving dotfiles
  imperative.
- ZFS/disko-based storage is modeled as declarative profiles
  (`modules/storage/zfs-profiles.nix`, `jupiter.storage.profile`) instead of
  ad hoc per-host `disko.nix` copies — `europa` is the sole deliberate
  exception (bespoke rpool/zvol layout), which is itself documented as an
  intentional escape hatch, not neglect.
- sops-nix-backed secrets are consumed via typed options
  (`config.sops.secrets.<name>.path`) rather than shelled into
  `environment.etc` or raw file writes.

### Deficiencies & Anti-patterns
- `modules/services/tcxwave-power-tuning.nix:160` uses
  `services.journald.extraConfig` (a raw INI string) where the same effect is
  largely expressible via structured attrs in newer NixOS — minor, but it's
  the one clear raw-string-config outlier flagged by the scan.
- Several `systemd.services.*` blocks with hand-rolled `ExecStart` shell
  logic exist in `modules/desktop/dashboard-gaming.nix`,
  `modules/services/state-backup.nix`, and `modules/storage/zfs-profiles.nix`
  where the task (session switching, `pg_dumpall`/rsync backup jobs, disko
  wiring) doesn't have an official NixOS module option to defer to — these
  are reasonably justified (there's no first-class "dump this DB to that iSCSI
  target" option upstream) but each is still an imperative shell script that
  won't get upstream security fixes or option-level validation.
- No NixOS module exists yet for HA/n8n's *internal* configuration — both are
  treated as opaque services/VM consumers of Postgres
  (`modules/services/home-assistant-vm.nix` notes the HA recorder `db_url` is
  set **inside the HAOS VM**, i.e. imperatively, not NixOS-managed). This is
  an inherent limitation of consuming HAOS as a VM appliance rather than a
  gap in this repo's own modules, but it does mean a meaningful slice of the
  home-automation config isn't declarative from this flake's point of view.
- No `vulnix`/CVE-scanning step and no automated "does this config still
  match reality" drift-check beyond boot-smoke — coverage of *what's
  declared* is strong, but there's no check that *what's declared* still
  matches what's deployed (relevant once real hardware is live).

---

## 4. Security & Hardening — 11/15

### Strengths
- All real secrets are sops-nix + age encrypted at rest
  (`secrets/secrets.yaml` — verified every value scanned is an `ENC[AES256_GCM,...]`
  blob, none in plaintext); recipients are enumerated per-host in `.sops.yaml`.
- Secrets are correctly kept out of the Nix store: sops-nix decrypts at
  activation time (not eval/build time), per `CLAUDE.md`'s Gotchas section —
  confirmed no secret material is interpolated directly into any
  store-path-bound string in the modules scanned.
- Inter-service credentials are policy-enforced to be machine-generated
  (`scripts/gen-secrets.sh`, documented in `CLAUDE.md` and `docs/roadmap.md`)
  rather than human-chosen — closes off weak/reused-password risk for
  service-to-service auth (Postgres roles, MQTT users, syncoid keypair).
- Firewall is default-closed with explicit, minimal per-service
  `allowedTCPPorts`/`allowedUDPPorts` (iSCSI 3260, NFS 2049, DNS 53, MQTT via
  an explicit `openFirewall` toggle, Loki, Syncthing) — no blanket
  `networking.firewall.enable = false` or wildcard port ranges found anywhere
  in the scan.
- `terraform/cloudflare/default.nix:35` and `terraform/unifi/default.nix:40`
  correctly reference secrets via Terraform variable interpolation
  (`"${var.cloudflare_api_token}"`) rather than inlining credentials into the
  generated HCL.

### Deficiencies & Anti-patterns
- **No SSH/login hardening beyond NixOS defaults** — `services.openssh.enable`
  is set in `modules/common.nix` with no `PermitRootLogin` override, no
  fail2ban/sshguard, and no 2FA/U2F on any host (self-identified in
  `docs/roadmap.md`'s "Operational maturity gaps" section, confirmed by grep:
  no `fail2ban`/`sshguard`/`security.pam.u2f` hits anywhere in `modules/`).
- **No kernel/kconfig hardening profile.** `boot.kernel.sysctl` is set only
  for ZFS ARC tuning (`modules/storage/zfs-tuning.nix:19`) and
  gaming-performance tuning (`modules/gaming/console.nix:315`,
  `modules/services/tcxwave-power-tuning.nix:43`) — none of it is
  security-hardening sysctls (no `kernel.kptr_restrict`,
  `kernel.yama.ptrace_scope`, `net.ipv4.conf.all.rp_filter`, etc.), and
  `security.lockKernelModules`/`nixos-hardened` are not used on any host.
  Reasonable for a trusted home-lab threat model, but worth stating
  explicitly as an accepted risk rather than an oversight.
- **Duplicate hardcoded password hash across two accounts.** In
  `hosts/ganymede/configuration.nix:101` and `:107` (VM-variant test build),
  `users.users.io` and `users.users.root` are both assigned the *same*
  literal `hashedPassword` string. This is scoped to
  `virtualisation.vmVariant` (QEMU boot-smoke testing only, not a real host
  credential) so it's low real-world risk, but reusing one hash across two
  accounts is still a bad habit worth breaking even in test-only code —
  either derive distinct throwaway hashes or comment explicitly why sharing
  is intentional.
- **No secrets-rotation mechanism.** `make gen-secrets` fills in *missing*
  credentials once; nothing rotates sops-nix age keys or already-generated
  passwords/the syncoid keypair on a cadence (self-identified gap,
  `docs/roadmap.md`).
- **No TLS/cert-expiry monitoring** independent of Cloudflare's own tunnel
  handling — only the `cloudflare_cert` secret exists; there's no ACME/cert
  pipeline being watched for expiry (self-identified gap, `docs/roadmap.md`).
- **No CVE/vulnerability scanning in CI** (`vulnix` or equivalent) — CI builds
  and boot-tests closures but never checks them against known nixpkgs
  advisories.

---

## 5. Ergonomics & Maintenance — 13/15

### Strengths
- `nix.gc` is configured and automatic (`modules/common.nix:116-119`:
  `automatic = true; dates = "weekly"; options = "--delete-older-than 14d";`)
  on every host inheriting `common.nix` — no manual GC burden.
- Documentation is unusually thorough for a personal repo: a full `docs/`
  tree (`01-architecture.md` through `10-terraform.md`) plus a living
  `docs/roadmap.md` that tracks decisions, staged PRs, and — notably — a
  self-audited "Operational maturity gaps" section dated 2026-07-01 that
  already anticipates several of this report's findings (SSH hardening,
  no metrics/alerting, no backup-restore verification, no secrets rotation).
  This is a strong maintenance signal: the team is already tracking its own
  debt rather than needing it externally discovered.
- Multi-host scalability is proven in practice, not just in theory: the four
  kiosk hosts (`metis`/`adrastea`/`amalthea`/`thebe`) are driven from one
  shared `jupiter.dashboardKiosk` module differing only by
  `jupiter.dashboardKiosk.url`, and the `jupiter.storage.profile`/
  `jupiter.backup` toggles mean a new state-holding host is backed up with
  zero edits to the NAS host (`europa`) — a well-designed "add a host, get
  the boilerplate for free" pattern.
- `make build-all`, `make test-<host>`, `make check`, `make fmt`/`fmt-check`
  give a complete, discoverable local dev-loop without needing to remember
  raw `nix` invocations.
- Post-deploy safety net exists: `deployActivate` in `flake.nix` wraps
  `deploy-rs` activation with a health check
  (`systemctl is-system-running` within 120s) that triggers automatic
  rollback on failure — a meaningfully more mature deploy story than "hope
  the switch works."

### Deficiencies & Anti-patterns
- In-code documentation is thin: modules rely on external `docs/*.md` for
  option-surface explanation rather than `lib.mkOption { description = ...; }`
  strings rich enough to self-document via `nixos-render-docs` — the two
  sources can and likely will drift (e.g. `docs/04-modules-reference.md`
  duplicating rather than being generated from module `description`s).
- No metrics/alerting/paging exists at all (Loki is log storage only, no
  Prometheus/Grafana/Alertmanager, no ntfy/healthchecks.io hook) — an outage
  is discovered by using the affected service, not by notification
  (self-identified, `docs/roadmap.md`).
- No backup-restore verification job — snapshots/replication/offsite all
  exist, but nothing periodically proves a snapshot is actually restorable.
- The whole repo is explicitly pre-deployment (`docs/roadmap.md`'s
  "Validation still required" section, and the flake-update secrets TODO
  in the roadmap) — none of the ergonomics claims above have been proven
  against real hardware yet, which caps how much credit "maintainability in
  practice" can take versus "maintainability on paper."

---

## Executive Summary

jupiter-os is an unusually disciplined home-lab NixOS monorepo — its
`jupiter.*` toggle architecture, generated-not-hand-set service credentials,
auto-wired backup topology, and self-auditing roadmap put it well ahead of
typical personal infrastructure-as-code in both structure and security
posture. The main gap holding it back from a higher score is operational
maturity the team has already identified but not yet closed — no
metrics/alerting, no SSH hardening beyond defaults, no secrets rotation, and
an as-yet-unvalidated deploy path against real hardware — rather than any
architectural rot in the Nix code itself.
