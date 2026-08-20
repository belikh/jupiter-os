# ADR-0002 — The arcade webapp is custom-built, not RomM

Date: 2026-08-21
Status: Accepted for D2–D4; D1 (custom vs RomM) accepted pending research
confirmation — see the D1 section
Plan: [docs/plans/arcade-webapp-gauntlet.md](../plans/arcade-webapp-gauntlet.md)
(Phase 0, items D1–D4)

## Context

The jupiterOS Arcade pipeline on europa is scattered across manual oneshots
(`jupiter-rom-dats` / `-acquire` / `-verify`), a scrape timer, an inventory
timer, and three operator surfaces (AriaNg, scripts, inventory JSON). The plan
commits to one NixOS-native webapp owning the whole pipeline — DAT currency,
aria2 downloads, igir verify, Skyscraper metadata, the Pegasus launcher DB,
curation, and one status dashboard — and requires the build-vs-buy choice to
be made from evidence before any implementation.

The buy candidate is [RomM](https://romm.app) (AGPL-3.0, ~12k stars): a
polished library/curation webapp with IGDB/ScreenScraper/Hasheous metadata
and, since 4.9, a per-platform `metadata.pegasus.txt` export. Evidence
gathered 2026-08-21 (docs.romm.app 5.1.0/5.0.0, romm.app, rommapp/romm,
search.nixos.org, NixOS wiki; full table in the plan §1.1) is summarized in
the framework below.

## Decision framework

Twelve criteria, scored custom (C) vs deploy-and-bend RomM (R) — the full
matrix with per-cell evidence is plan §1.2. Condensed:

| # | Criterion | Custom | RomM |
|---|---|---|---|
| 1 | DAT currency (Fresh1G1R McLean 1G1R) | build (already proven in `fetch-mclean-1g1r-dats.sh`) | **forfeit** — no DAT concept |
| 2 | aria2 download management | build (JSON-RPC; `aria2-rpc.sh` semantics ported) | **forfeit** — no acquisition anywhere |
| 3 | igir verify + organize | build (exec igir, parse CSV report) | **forfeit** — filename/hash-match only |
| 4 | Metadata via existing Skyscraper cache | drive Skyscraper as-is (cache investment kept) | re-scrapes through its own stack, re-hits ScreenScraper quotas |
| 5 | Launcher DB → `metadata.pegasus.txt` | full control (launch lines, collections, atomic swaps) | 4.9+ export exists; shape control unverified → D1 research |
| 6 | Curation (hide/show, collections) | build | native, polished — R's piece |
| 7 | Pipeline dashboard | build (incl. state RomM cannot express) | library stats only |
| 8 | Kiosk compatibility (hard constraint) | zero kiosk-side change | needs symlink farm + slug remap + export-shape control, each unverified |
| 9 | NixOS/house fit | pure nix, zero containers, no new flake input | first container runtime on europa + mariadb + redis on a 2-core NAS |
| 10 | AGPL posture | repo untouched | unmodified use clean; any bend = public fork; **zero RomM code may enter this repo** |
| 11 | Single-system property | yes | no — 1–4 stay scripts = sprawl persists, split across two UIs |
| 12 | Time-to-credible-UI | the risk (we build the gallery) | free (12k-star React SPA) |

The per-piece gauntlet structure of the plan is what makes criteria 1–3
decisive: pieces are judged individually, so RomM's forfeit pieces are free
wins for a competent custom build, while its strong pieces (library,
curation) must be won head-to-head *regardless of which backend serves them*.
Deploying RomM and keeping the pipeline = two systems; bending RomM = an
AGPL fork of a ~100k-line Python/React codebase vs a ~5k-line Go app we
fully own.

## D1 — custom vs RomM: **CUSTOM** (pending research confirmation)

CUSTOM wins on structural forfeits: RomM has **no download management**, **no
DAT-based verification**, would put the **first container runtime on europa**
(plus mariadb + redis on a 2-core HDD NAS), and its **AGPL** license means
any bend is a public fork with zero code reusable here. Criteria 1, 2, 3, 9
and 11 are not "RomM is worse" — they are "RomM cannot do it at all."

This verdict is **provisional until the parallel Phase 0 research completes**
(throwaway NixOS VM via `virtualisation.oci-containers`, never europa):
multi-root library workarounds, the actual shape of RomM's Pegasus export
(`launch:` lines, `directory:`, collections, hidden games — criteria 5 and 8),
and the concrete cost of bending. The research can only refine the forfeit
margins or surface a surprise in criteria 5/8; it cannot invent download
management or DAT verification. What would flip D1 to RomM: the export
proving fully controllable (our launch lines, collections, hide-flags, NFS
layout) AND the household valuing RomM's gallery over pipeline integration —
judged against the plan's criteria, not taste. Until the research lands, no
RomM code, config, or container enters this repo.

## D2 — app placement: in-tree `pkgs/arcade-webapp/`

Source + templates live in-tree at `pkgs/arcade-webapp/`, exposed as the
flake package `packages.x86_64-linux.arcade-webapp` (built with untuned
`nixpkgs.legacyPackages` like suno-backup/nom-web, so `nix build
.#arcade-webapp` recomputes the vendorHash without pulling europa's closure).
Phase 1 wires a `modules/services/arcade-webapp.nix` that consumes it via
`pkgs.callPackage` — the suno-backup/nom-web/dsh precedent. **No new flake
input** (buildability rule: an input needs a registered host that uses it;
the fleet pin's `buildGoModule` covers this app). The suno-web precedent
(own repo + flake input) is the documented escape hatch if the app grows a
life outside this fleet.

## D3 — database: SQLite (pure-Go driver), on-pool state file

Single SQLite file under `/tank/archive/retro/state/` (on-pool per ADR-0001's
boundary rule — it is runtime state, not config), **WAL mode**, accessed via
`modernc.org/sqlite` — pure Go, no cgo, so the package substitutes cleanly
from cache.nixos.org on every host. Single writer on a single host is
SQLite's sweet spot; europa is a 2-core NAS and will not run a database
daemon for this. Postgres only if a concurrent-writer need appears (it won't
on this fleet). Consequence for D2's package: the stub stays stdlib-only
(`vendorHash = null`); importing the driver in Phase 1 flips `vendorHash` to
a real hash via the standard buildGoModule bump procedure.

## D4 — stack: Go stdlib `net/http` + `html/template` + htmx + hand-rolled CSS

Server-rendered Go with `html/template`, **htmx as one vendored JS file**
(no CDN fetch, no node in the closure), hand-rolled CSS. No SPA framework,
no build step beyond `buildGoModule`. Precedent: suno-web (stdlib-only Go).
The webapp serializes pipeline jobs internally (R5) — there is no
client-side state worth a framework.

**Escalation trigger (documented reversal):** if the blind critic rejects the
gallery pieces (P4/P7) **twice** on polish grounds *specifically attributable
to server-rendering*, the front half escalates to a vite/preact island layer
built with `buildNpmPackage` — the house already ships npm-built packages
(ariang, dsh, aeon). Escalation is per-piece, keeps D2/D3 untouched, and
must be recorded in the progress page's decision log with both critic
verdicts linked.

## AGPL posture

RomM is AGPL-3.0. **Zero RomM code may enter this repository** — not
copied, not adapted, not "referenced for inspiration" in a way that creates
a derivative. If D1 were ever flipped to RomM, it would run unmodified in a
container and this repo would only ever reference its API; any fork lives in
its own public repo (plan R3). The custom app is written from scratch and
MIT-licensed like the rest of `pkgs/`.

## Consequences

+ One system owns the pipeline end-to-end (criterion 11); the forfeit pieces
  (DAT currency, downloads, verify) become gauntlet wins instead of gaps.
+ Zero containers on europa, no new flake input, no database daemons;
  everything substitutes from cache.nixos.org.
+ Kiosks stay untouched: same `game_dirs`, same read-only NFS (A2).
+ The gallery UI is now ours to win: criteria 6 and 12 are real risk,
  mitigated by the gauntlet's concentrated builder/critic loops on P4/P7,
  real art from day one, and D4's escalation trigger.
+ Fixture corpus (Phase 0 item 6) makes the verify pipeline testable with
  zero copyrighted material: self-authored DATs over self-authored dummy
  ROMs, `igir copy test report` gated to zero unmatched.
- ~5k lines of Go we maintain instead of a 12k-star app we don't.
- The D1 research may still surface export-shape surprises (criteria 5/8);
  if so they are scored into the matrix, not silently absorbed.
