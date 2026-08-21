# ADR-0002 — The arcade webapp is custom-built, not RomM

Date: 2026-08-21
Status: Accepted — D1 research-confirmed 2026-08-21 (see the D1 section);
D2–D4 accepted
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
| 1 | DAT currency (Fresh1G1R McLean 1G1R) | build (already proven in `fetch-mclean-1g1r-dats.sh`) | **forfeit** — no local DAT concept (Hasheous cloud-hash "verified" filter only — F2) |
| 2 | aria2 download management | build (JSON-RPC; `aria2-rpc.sh` semantics ported) | **forfeit** — no acquisition anywhere |
| 3 | igir verify + organize | build (exec igir, parse CSV report) | **forfeit** — filename/hash-match only |
| 4 | Metadata via existing Skyscraper cache | drive Skyscraper as-is (cache investment kept) | re-scrapes through its own stack, re-hits ScreenScraper quotas |
| 5 | Launcher DB → `metadata.pegasus.txt` | full control (launch lines, collections, atomic swaps) | 4.9+ export exists but **cannot emit `launch:`/collections and does not exclude hidden games** (F3) |
| 6 | Curation (hide/show, collections) | build | native, polished — R's piece |
| 7 | Pipeline dashboard | build (incl. state RomM cannot express) | library stats only |
| 8 | Kiosk compatibility (hard constraint) | zero kiosk-side change | needs symlink farm + slug remap + export-shape control, each unverified |
| 9 | NixOS/house fit | pure nix, zero containers, no new flake input | native `services.romm` in nixpkgs master since 2026-08-11 (F1) — container argument void; ScreenScraper dev-creds gap undermines its scraper story |
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

## D1 — custom vs RomM: **CUSTOM** (research-confirmed 2026-08-21)

CUSTOM wins on structural forfeits — RomM has no acquisition/download
management, no local DAT verification, and its AGPL means any bend is a
public fork with zero code reusable here (criteria 1, 2, 3, 10, 11).
Adversarial source-level research completed (romm master `42e80433`,
2026-08-19: `backend/utils/pegasus_exporter.py` + tests + config manager;
docs.romm.app live pages; nixpkgs; RomM GitHub issues). It **confirmed the
decision** and corrected three facts in the plan's evidence table. The
scoring outcome does not change — criteria 1–3 remain structural forfeits —
but the decision now stands on accurate ground:

- **F1 (correction, high):** "RomM not in nixpkgs / needs containers on
  europa" is **stale**. nixpkgs PR
  [#547607](https://github.com/NixOS/nixpkgs/pull/547607) (merged 2026-08-11)
  ships `romm` 5.1.0 plus a full native `services.romm` NixOS module
  (PostgreSQL, dedicated redis, nginx vhost with X-Accel-Redirect downloads,
  hardened services, NixOS test). Our flake lock (2026-08-01) predates the
  merge by ten days. This voids the container/host-fit argument but does
  **not** flip the decision: criteria 1–3, 5, and 11 still fall to custom.
  Bonus finding: source-built RomM lacks upstream's embedded ScreenScraper
  *developer* credentials (baked from CI secrets in the official image), so
  `services.romm` ScreenScraper scraping 403s until `SCREENSCRAPER_DEV_*`
  is supplied via `environmentFile` — actively undermining RomM's scraper
  story on nixpkgs (our Skyscraper cache path keeps those quotas untouched).
- **F2 (correction, medium):** RomM **has** a Hasheous cloud-hash "verified"
  filter — per-ROM booleans for No-Intro/Redump/TOSEC/MAME signature matches
  (`hasheous_handler.py`) surfaced as a library filter. It is not local DAT
  verification: no DAT files on disk, no DAT currency, no organize/promote,
  no missing-set reporting. Criterion 1/3 is therefore phrased "no local DAT
  verification/organize", not "no No-Intro concept".
- **F3 (settles criterion 5):** RomM's Pegasus export **cannot drive our
  kiosks** — verified in the implementation at master `42e80433`: it emits
  **no `launch:` lines** (no config key exists anywhere; the only control is
  `scan.pegasus.export: true`), no per-game `directory:` (bare `file:`
  filenames relative to the platform dir), **no collections** (one
  auto-named platform block from a slug table; custom/smart/virtual
  collections absent), does **not exclude hidden games** (hidden is a
  per-user flag the exporter never reads), writes non-atomically into the
  library tree, and skips existing (stale) asset files. Caveat recorded for
  D1 experimenters: docs.romm.app's export example shows `launch:` and
  absolute-path `file:` lines **the code never emits** — this ADR cites the
  code, not that snippet. Kiosk launch lines are our differentiator, not
  parity.

The throwaway-VM RomM experiment (plan §1.3 item 1) is demoted to **optional
confirmation**: the source evidence is decisive and no Phase 1 work is
blocked on it. The would-be flip condition — the export proving fully
controllable (our launch lines, collections, hide-flags, NFS layout) AND the
household valuing RomM's gallery over pipeline integration — is now known to
be unmet on its first leg: F3 shows the export is not shape-controllable.

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
- D1 research landed (2026-08-21) with three fact corrections (F1–F3 above)
  folded into this ADR and the plan's decision log; no export-shape surprise
  remains open — criterion 5 is settled against RomM (F3).
