# Arcade Webapp Gauntlet — Progress

The live heartbeat of the builder/critic loop driving
[the plan](arcade-webapp-gauntlet.md). Updated at every piece boundary and
every critic verdict. Screenshots (when they exist) land under
`arcade-webapp-gauntlet/` next to this file.

- **Phase:** 1 **P1 in review — adversarial findings reconciled** (5 fixed,
  3 accepted; blind critic is next)
- **Branch:** `arcade/webapp-gauntlet`
- **ADR:** [ADR-0002 — custom, not RomM](../adr/0002-arcade-webapp-custom-vs-romm.md)
  (D1 research-confirmed 2026-08-21; D2–D4 accepted)
- **Last update:** 2026-08-21 14:05 AEST

## Piece table

| Piece | State | Builder loops | Last critic verdict | Critic's named gap | Evidence |
|---|---|---|---|---|---|
| P1 — Pipeline dashboard | review | 1 (review round: 5 findings fixed, 3 accepted) | — | — | reconciliation table below |
| P2 — Download control | pending | 0 | — | — | — |
| P3 — Verify & organize | pending | 0 | — | — | — |
| P4 — Library browsing | pending | 0 | — | — | — |
| P5 — Metadata engine control | pending | 0 | — | — | — |
| P6 — Launcher DB generator | pending | 0 | — | — | — |
| P7 — Curation | pending | 0 | — | — | — |
| P8 — eXo integration + sprawl retirement | pending | 0 | — | — | — |

States: `pending` → `building` → `review` → `critic-loop` → `won` / `blocked`.
A piece is **won** only on a recorded fresh-context critic verdict "ours"
(labels stripped, comparable data); exit is the 8 wins, never a round count.

## Verification log

Mirrors the open-ultracode verification records: every standing check at
every boundary, pass/fail/blocked — never asserted without a run.

### Phase 0

| Command | Result | Notes |
|---|---|---|
| `nix build .#arcade-webapp` | **pass** (2026-08-21) | verified again post-fixture (subPackages pins the package to `cmd/arcade-webapp` only); `result/bin/arcade-webapp` |
| `go test ./...` (in `pkgs/arcade-webapp`) | **pass** (2026-08-21) | `internal/web` handler tests + `internal/fixture`: DAT↔generator hash equivalence (both directions), determinism, idempotence + stale-DAT guard, name invariants, DAT byte-stability |
| `make fixture-arcade` | **pass** (2026-08-21) | gate: igir 5.3.0 (pinned via flake-locked nixpkgs) `copy test report` per system with cartridge-verify.sh's exact flags — **nes 5/5, snes 4/4, gb 4/4 FOUND, 0 UNUSED (zero unmatched)**; negative control (method: run gate once, corrupt a ROM under `tests/fixtures/arcade/incoming`, re-run with `SKIP_REGEN=1 make fixture-arcade` — regeneration is skipped so corruption survives to igir) fails the gate ✓; UNUSED tripwire verified against a probe CSV ✓ |
| `make fmt` then `make fmt-check` | **pass** (2026-08-21) | clean at the Phase 0 boundary |
| `make check` | **pass** (2026-08-21) | `nix flake check --no-build` — every host still evals |
| D1 RomM research | **pass** (2026-08-21) | adversarial source-level research confirmed CUSTOM with corrections F1–F3 (ADR-0002 §D1); runtime VM experiment optional, not blocking |

### Phase 1 (P1 — pipeline dashboard)

| Command | Result | Notes |
|---|---|---|
| `go test -count=1 ./...` (in `pkgs/arcade-webapp`) | **pass** (2026-08-21) | new suites: `internal/catalogue` (TSV semantics incl. the committed 61-row fleet TSV; skipped in the nix sandbox where the repo root is unreachable — covered by the VM test), `internal/store` (WAL, idempotent migrate, rescan never clobbers hidden/verify_state, summary joins), `internal/scanner` (fixture-tree scan: 5/4/4 games, DAT 2026-08-21 v1.0, coverage 60/100/0%, inventory import + absence, ErrBusy serialization, DAT header stream-parse), `internal/web` (render smoke over the real templates: card markers, fragment-shaped partials, rescan records a 2nd run, htmx banner + LICENSE + css served, 404s) |
| `nix build .#arcade-webapp` | **pass** (2026-08-21, after correction) | first `got:` hash was **hollow** — captured while the new Go files were still untracked, so the flake source carried no sqlite import and `go mod vendor` vendored nothing while the old stub still compiled. Caught by forcing a rebuild of the go-modules FOD (`nix-store --realise --check`); corrected hash `sha256-BAvf…`, full rebuild + binary smoke (healthz, 3 fixture cards) re-verified |
| `make fixture-arcade` | **pass** (2026-08-21) | igir gate still green post-P1: nes 5/5, snes 4/4, gb 4/4 FOUND, **0 unmatched** |
| `make fmt` then `make fmt-check` | **pass** (2026-08-21) | clean |
| `make check` | **pass** (2026-08-21) | all hosts eval incl. the new `arcade-webapp-vm` — needed the classic grub `nodev` + by-label root placeholder because flake check asserts toplevel bootability (test host boots direct-kernel) |
| `make test-arcade-webapp` | **pass** (2026-08-21, 3 runs incl. final config) | real module + real fleet TSV (61 systems) against the deterministic fixture tree; in-VM smoke asserts: `/healthz` 200, dashboard cards `nes data-games="5" data-coverage="60"`, `snes 4/100%`, `gb 4/0%`, fixture DAT date rendered, 58-empty-systems footer, partials fragment-shaped, `POST /rescan` → 202 + second run recorded. Two real module bugs found and fixed en route (see D-P1e/D-P1f) |

### Phase 1 adversarial review — reconciliation (2026-08-21)

Verdict **FIX**; 8 findings: **5 fixed** (`e423d5a`…`429ada1`), **3 accepted
with rationale**, none rejected. Piece stays in `review` until the blind critic.

| Finding | Disposition | What changed |
|---|---|---|
| ADV-P1-01 HIGH — walk missed zips + cue/bin companions | **fixed** (`e423d5a` + VM fixture in `429ada1`) | `scanSystemDir` extracted with real-tree semantics: game = extension match ∪ zip; companion bytes attributed (sole game in dir absorbs, else longest basename prefix); bare .bin not a game unless listed (a2600); dotfiles never count. RED→GREEN `walk_test.go` (7 tests). VM fixture now carries 2 nes zips + a segacd cue/bin rip, asserted end-to-end (nes 7/42%, segacd 1 game · 6.1 KiB, 57 empty) |
| ADV-P1-02 MED — McLean DAT dates unparsed | **fixed** (`4cf6a98`, expectation fix `4ccca7c`) | AgeDays layouts += `"2006-01-02 15-04-05"` + colon variant; committed header-shape `testdata/dats/mclean-shape.dat` (shape only). RED: AgeDays = −1 on `"2026-06-22 07-44-23"`; GREEN: 59 (truncation — see below) |
| ADV-P1-03 MED — walk error pruned games rows | **fixed** (`7503dd3`) | scanAll replaces only after a clean walk (absent dir = deliberate zero); any walk error keeps previous rows + a "kept previous rows" warning. RED needed a 1.1s sleep: the prune compares RFC3339-second `last_seen_at` strings, so a same-second rescan masked the wipe (`nes rows = 0, want 5` across the boundary) |
| ADV-P1-04 MED — VM FAIL verdict raced autologin/timeout | **fixed** (`429ada1`) | autologin getty dropped (smoke is a service, needs no shell); fail()/pass() sync + settle 1s before poweroff. Mutation re-proof: impossible grep → `ARCADE-WEBAPP-VM: FAIL` in the serial log, make exit 1, **48 s wall** (was a silent 300 s burn); restored → clean PASS |
| ADV-P1-05 LOW — warnings invisible + raw JSON detail | **fixed** (`9b83e84`) | health chip order scanning > error > N warnings > stale DATs > healthy; `runDetail` renders "N systems · G games · size" + up to 3 ⚠ lines (escaped, capped), non-scan payloads escaped+truncated, never raw JSON. RED→GREEN web tests |
| ADV-P1-06 — Go TSV parser more lenient than Nix regex | **accepted** (doc sentence added in `e423d5a`) | benign: both agree on the committed TSV; Nix eval fails first on drift. Documented in the catalogue package comment |
| ADV-P1-07 — /rescan has no CSRF check | **accepted, revisit in P2+** | bounded (LAN-only service, rescan is idempotent read-refresh) and sibling-consistent (suno-web/nom-web have no CSRF either); P2 adds state-mutating endpoints (pause/remove downloads) — CSRF review lands with them |
| ADV-P1-08 — openFirewall is all-interfaces | **accepted, no change** | sibling-consistent with suno-web/aria2 modules on the same trusted LAN; interface-scoped binding is a fleet-wide pattern change, not a P1 fix |

### Phase 1 post-review verification (fresh, on the reconciled tree)

| Command | Result | Notes |
|---|---|---|
| `go test -count=1 ./...` (in `pkgs/arcade-webapp`) | **pass** (2026-08-21) | now incl. `walk_test.go` (zip/cue-bin/bin-listed/dotfile shapes), McLean date parsing, unreadable-dir row preservation, warning chip + humanized detail |
| `make fixture-arcade` | **pass** (2026-08-21) | still zero-unmatched; the corpus DATs/ROMs were untouched (VM fixture shapes live only in the test host derivation) |
| `nix build .#arcade-webapp` | **pass** (2026-08-21) | no vendorHash change (stdlib-only edits since the flip) |
| `make fmt` then `make fmt-check` | **pass** (2026-08-21) | clean, no diff |
| `make check` | **pass** (2026-08-21) | every host evals |
| `make test-arcade-webapp` | **pass** (2026-08-21) | upgraded fixture assertions (nes 7 games/42% with zips, segacd cue+bin 1 game/6.1 KiB, 57 empty); mutation FAIL proof 48 s + exit 1, then clean PASS |

## Decision log

| Decision | Verdict | Status | Evidence |
|---|---|---|---|
| D1 — custom vs RomM | **CUSTOM** — confirmed by adversarial source-level research (romm master `42e80433`, nixpkgs, live docs). Criteria 1–3/11 are structural forfeits (no acquisition, no local DAT verify/organize, two-system sprawl). Three fact corrections folded into ADR-0002: **F1** native `services.romm` shipped in nixpkgs PR #547607 (2026-08-11) — container argument void, decision unchanged (ScreenScraper dev-creds gap undermines RomM's scraper story on nixpkgs); **F2** RomM's Hasheous cloud-hash "verified" filter exists but is not local DAT verification; **F3** Pegasus export emits no `launch:`/no collections/hidden not excluded (code-verified) — cannot drive our kiosks | **decided** (runtime VM experiment demoted to optional confirmation; not blocking Phase 1) | ADR-0002 §D1 + criterion-table corrections; research evidence: romm master `42e80433` `backend/utils/pegasus_exporter.py`, [nixpkgs#547607](https://github.com/NixOS/nixpkgs/pull/547607), docs.romm.app exports page (its example shows lines the code never emits — ADR cites code) |
| D2 — app placement | in-tree `pkgs/arcade-webapp/`, flake package `arcade-webapp`, module consumes via `pkgs.callPackage`; **no new flake input** | decided | ADR-0002 §D2 (suno-backup/nom-web precedent) |
| D3 — database | SQLite, single file under `/tank/archive/retro/state/`, WAL, `modernc.org/sqlite` (pure Go, no cgo) | decided | ADR-0002 §D3 |
| D4 — stack | Go stdlib `net/http` + `html/template` + htmx (one vendored file) + hand-rolled CSS; no node/SPA. Escalation: two critic rejections of P4/P7 polish attributable to server-rendering → vite/preact islands via `buildNpmPackage` | decided | ADR-0002 §D4 |
| D-P1a — htmx license fact correction | htmx as of 2.x is **0BSD**, not BSD-2-Clause as plan §1.3 stated (verified: upstream `package.json` `"license": "0BSD"` + the LICENSE file at v2.0.10). Vendored per AR-006 anyway: upstream LICENSE next to `htmx.min.js`, version + source + sha384 integrity (matches htmx.org's published hash) in a banner comment. 0BSD is strictly more permissive — vendoring posture unchanged | decided (fact correction) | `pkgs/arcade-webapp/internal/web/static/htmx.min.js` banner + `htmx-LICENSE` |
| D-P1b — secret-path options: declared now, consumed by P2/P5 | the module takes the three secret-PATH options (`aria2SecretFile`, `screenscraperCredsFile`, `tgdbApikeyFile`, `nullOr path`, default null) and the app records **presence only** (stat, never content); the sops *declarations* + env wiring land with the phases that actually read the values (P2 aria2, P5 scrape). Rationale: no dead secrets in units that don't use them, and the VM host stays sops-free (its options point at `/dev/null`) | decided | `modules/services/arcade-webapp.nix` option docs; `cmd/arcade-webapp/main.go` presence-only logging |
| D-P1c — card wall renders active systems only | a system gets a card iff it has ROMs, a DAT, or cache coverage; empty catalogue systems (58 of 61 on the fixture VM) collapse into one footer line. Rationale: P1's bar is "is the pipeline healthy in 5 s" — 58 zero-cards bury the signal | decided | `internal/web` Active() + partial template |
| D-P1d — service runs as root, not DynamicUser | the SQLite state is on-pool per ADR-0002 D3 (`/tank/archive/retro/state`); a dynamic uid cannot own that path. suno-backup precedent: root + `commonServiceHardening` + `ProtectSystem=strict`, write ONLY stateDir, trees read-only | decided | `modules/services/arcade-webapp.nix` serviceConfig comment |
| D-P1e — vendorHash must be captured from a clean flake source | the Phase-1 hash flip initially recorded a hollow hash: `go mod vendor` saw a source whose new Go files were still untracked (flake source = git-tracked files), so it vendored nothing and the stale stub still compiled. Rule adopted: flip hashes only with everything staged/committed, and sanity-check `ls vendor/modernc.org` in the FOD output before trusting a green build | decided (process) | verification log correction above; commits `657f2f3` (fix), `79ab9fb` (original flip) |
| D-P1f — state dir: tmpfiles BEFORE namespace, never under /tmp | with `ProtectSystem=strict`, systemd builds the mount namespace (ReadWritePaths) before ExecStartPre — a missing dir fails the unit at step NAMESPACE 226 and a preStart mkdir can never save it → the module ships a tmpfiles rule + `after = systemd-tmpfiles-setup.service`. Separately, `PrivateTmp=true` means a `/tmp` state dir exists only in the unit's private namespace — the VM host therefore uses `/var/lib/…` (europa's on-pool path is unaffected) | decided | `modules/services/arcade-webapp.nix` tmpfiles rule; `tests/hosts/arcade-webapp-vm.nix` stateDir comment |

## Gauntlet scoreboard

**0 won / 8 remaining.** Exit (AC-10) = every piece P1–P8 won with the final
named-gap=null or an accepted-residual note recorded in the piece table.
