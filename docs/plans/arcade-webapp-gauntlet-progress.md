# Arcade Webapp Gauntlet — Progress

The live heartbeat of the builder/critic loop driving
[the plan](arcade-webapp-gauntlet.md). Updated at every piece boundary and
every critic verdict. Screenshots (when they exist) land under
`arcade-webapp-gauntlet/` next to this file.

- **Phase:** 0 **complete** (exit gate met: D1–D4 decided with evidence,
  ADR committed, fixture igir-green, stub building, fmt/check green) —
  Phase 1 (P1 dashboard) is next
- **Branch:** `arcade/webapp-gauntlet`
- **ADR:** [ADR-0002 — custom, not RomM](../adr/0002-arcade-webapp-custom-vs-romm.md)
  (D1 research-confirmed 2026-08-21; D2–D4 accepted)
- **Last update:** 2026-08-21 11:20 AEST

## Piece table

| Piece | State | Builder loops | Last critic verdict | Critic's named gap | Evidence |
|---|---|---|---|---|---|
| P1 — Pipeline dashboard | pending | 0 | — | — | — |
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
| `make fixture-arcade` | **pass** (2026-08-21) | gate: igir 5.3.0 (pinned via flake-locked nixpkgs) `copy test report` per system with cartridge-verify.sh's exact flags — **nes 5/5, snes 4/4, gb 4/4 FOUND, 0 UNUSED (zero unmatched)**; negative control (corrupted ROM) fails the gate ✓; UNUSED tripwire verified against a probe CSV ✓ |
| `make fmt` then `make fmt-check` | **pass** (2026-08-21) | clean at the Phase 0 boundary |
| `make check` | **pass** (2026-08-21) | `nix flake check --no-build` — every host still evals |
| D1 RomM research | **pass** (2026-08-21) | adversarial source-level research confirmed CUSTOM with corrections F1–F3 (ADR-0002 §D1); runtime VM experiment optional, not blocking |

## Decision log

| Decision | Verdict | Status | Evidence |
|---|---|---|---|
| D1 — custom vs RomM | **CUSTOM** — confirmed by adversarial source-level research (romm master `42e80433`, nixpkgs, live docs). Criteria 1–3/11 are structural forfeits (no acquisition, no local DAT verify/organize, two-system sprawl). Three fact corrections folded into ADR-0002: **F1** native `services.romm` shipped in nixpkgs PR #547607 (2026-08-11) — container argument void, decision unchanged (ScreenScraper dev-creds gap undermines RomM's scraper story on nixpkgs); **F2** RomM's Hasheous cloud-hash "verified" filter exists but is not local DAT verification; **F3** Pegasus export emits no `launch:`/no collections/hidden not excluded (code-verified) — cannot drive our kiosks | **decided** (runtime VM experiment demoted to optional confirmation; not blocking Phase 1) | ADR-0002 §D1 + criterion-table corrections; research evidence: romm master `42e80433` `backend/utils/pegasus_exporter.py`, [nixpkgs#547607](https://github.com/NixOS/nixpkgs/pull/547607), docs.romm.app exports page (its example shows lines the code never emits — ADR cites code) |
| D2 — app placement | in-tree `pkgs/arcade-webapp/`, flake package `arcade-webapp`, module consumes via `pkgs.callPackage`; **no new flake input** | decided | ADR-0002 §D2 (suno-backup/nom-web precedent) |
| D3 — database | SQLite, single file under `/tank/archive/retro/state/`, WAL, `modernc.org/sqlite` (pure Go, no cgo) | decided | ADR-0002 §D3 |
| D4 — stack | Go stdlib `net/http` + `html/template` + htmx (one vendored file) + hand-rolled CSS; no node/SPA. Escalation: two critic rejections of P4/P7 polish attributable to server-rendering → vite/preact islands via `buildNpmPackage` | decided | ADR-0002 §D4 |

## Gauntlet scoreboard

**0 won / 8 remaining.** Exit (AC-10) = every piece P1–P8 won with the final
named-gap=null or an accepted-residual note recorded in the piece table.
