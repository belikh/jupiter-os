# Arcade Webapp Gauntlet — Progress

The live heartbeat of the builder/critic loop driving
[the plan](arcade-webapp-gauntlet.md). Updated at every piece boundary and
every critic verdict. Screenshots (when they exist) land under
`arcade-webapp-gauntlet/` next to this file.

- **Phase:** 0 — evaluation, ADR, fixture corpus, stub (in flight; P1–P8 pending)
- **Branch:** `arcade/webapp-gauntlet`
- **ADR:** [ADR-0002 — custom, not RomM](../adr/0002-arcade-webapp-custom-vs-romm.md)
  (D2–D4 accepted; D1 pending research confirmation)
- **Last update:** 2026-08-21 09:33 AEST

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
| `nix build .#arcade-webapp` | pending | lands with the stub + flake wiring commit |
| `go test ./...` (in `pkgs/arcade-webapp`) | pending | stub handler tests + fixture corpus tests (determinism, DAT well-formed) |
| `make fixture-arcade` | pending | gate: `igir copy test report` per system with zero unmatched |
| `make fmt` then `make fmt-check` | pending | run at the Phase 0 boundary |
| `make check` | pending | `nix flake check --no-build` — every host still evals |
| D1 RomM VM experiment | blocked (parallel research in flight) | runs in a throwaway VM, never europa; D1 verdict pending-research until it lands |

## Decision log

| Decision | Verdict | Status | Evidence |
|---|---|---|---|
| D1 — custom vs RomM | **CUSTOM** — wins on structural forfeits: no download mgmt, no DAT verify, first container runtime on europa, AGPL | pending-research (parallel Phase 0 VM experiment confirming the ☐ cells: multi-root layout, Pegasus-export shape, bend cost) | plan §1.1 fact table (docs.romm.app 5.1.0/5.0.0, romm.app, rommapp/romm, search.nixos.org, fetched 2026-08-21); ADR-0002 §D1 |
| D2 — app placement | in-tree `pkgs/arcade-webapp/`, flake package `arcade-webapp`, module consumes via `pkgs.callPackage`; **no new flake input** | decided | ADR-0002 §D2 (suno-backup/nom-web precedent) |
| D3 — database | SQLite, single file under `/tank/archive/retro/state/`, WAL, `modernc.org/sqlite` (pure Go, no cgo) | decided | ADR-0002 §D3 |
| D4 — stack | Go stdlib `net/http` + `html/template` + htmx (one vendored file) + hand-rolled CSS; no node/SPA. Escalation: two critic rejections of P4/P7 polish attributable to server-rendering → vite/preact islands via `buildNpmPackage` | decided | ADR-0002 §D4 |

## Gauntlet scoreboard

**0 won / 8 remaining.** Exit (AC-10) = every piece P1–P8 won with the final
named-gap=null or an accepted-residual note recorded in the piece table.
