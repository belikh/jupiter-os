# Arcade Webapp Gauntlet — Plan

Branch: `arcade/webapp-gauntlet` (base `main`) · Date: 2026-08-21
Status: **PLAN (drives a builder/critic loop)** · Bar: beat [RomM](https://romm.app)
([demo.romm.app](https://demo.romm.app), [rommapp/romm](https://github.com/rommapp/romm),
AGPL-3.0, ~12k stars) per piece, blind, labels stripped.

## Planning Report (summary)

- **GOAL:** One NixOS-native webapp on europa that owns the whole jupiterOS Arcade
  pipeline — DAT currency (Fresh1G1R McLean 1G1R), aria2 download management,
  igir verify/organize, Skyscraper metadata, the launcher database that generates
  `metadata.pegasus.txt` + `media/` for the read-only Pegasus kiosks, curation
  (hide/show + custom collections), and a single status dashboard — replacing
  today's sprawl of scripts and oneshot/timer units.
- **ACCEPTANCE_CRITERIA:** AC-1…AC-10 below (mapped to the 7 goal capabilities +
  the measurable half + house rules + gauntlet exit).
- **ASSUMPTIONS:** see "Assumptions" — headline: europa stays the pipeline host,
  kiosk client-side change is zero (same game_dirs, same read-only NFS), the
  catalogue TSV stays the system-facts source of truth, SQLite is adequate
  (single writer, single host).
- **RISKS:** see "Risks" — headline: beating RomM's gallery UI head-to-head,
  ScreenScraper rate limits, AGPL boundary if any RomM code is reused, europa's
  2-core/HDD budget, QEMU kiosk-launch test feasibility.
- **STEPS:** Phase 0 (RomM-vs-custom evaluation → ADR) → 1 foundation+dashboard →
  2 pipeline control (downloads / verify / metadata — the pieces RomM forfeits) →
  3 library browsing + curation (head-to-head) → 4 launcher DB generation +
  kiosk cutover + sprawl retirement → 5 end-to-end gauntlet + PR.
- **VERIFICATION:** per-phase commands (`make check`, `make fmt-check`,
  `nix build .#arcade-webapp`, `go test`, fixture igir zero-unmatched, new
  `make test-arcade-webapp` VM smoke, launch-probe test, coordinator-gated live
  observation on europa/amalthea) + the blind critic protocol per piece.

---

## 1. Phase 0 — RomM vs custom: evaluation with evidence and a decision gate

This is the highest-leverage decision; it is made **from evidence, not taste**,
and it is *provisional until the Phase 0 exit gate*. Facts already gathered
(sources: docs.romm.app 5.1.0 / 5.0.0, romm.app, rommapp/romm examples,
NixOS wiki/Docker docs — all fetched 2026-08-21):

### 1.1 Verified RomM facts (evidence on record)

| Fact | Evidence |
|---|---|
| RomM 5.1.0 metadata providers: IGDB, ScreenScraper, MobyGames, LaunchBox, Hasheous, PlayMatch, SteamGridDB, RetroAchievements, Flashpoint, HLTB, ES-DE gamelist import (+ TheGamesDB listed on romm.app) | docs.romm.app → Metadata Providers; romm.app |
| **Pegasus export exists since 4.9** — `scan.pegasus.export: true` writes `metadata.pegasus.txt` per platform; re-runs on scan or manual `POST /api/export/pegasus`; ES-DE `gamelist.xml` export too | docs.romm.app 5.0.0 → Reference → Exports; 4.9 release notes (Umbrel changelog) |
| **No download management** — no aria2/torrent/acquisition integration anywhere in docs or repo | docs.romm.app full nav; rommapp/romm README |
| **No DAT-based verification** — matching is filename + IGDB/Hasheous/PlayMatch hashes; no No-Intro DAT concept, no igir | docs.romm.app → Scanning/Metadata Providers |
| Deployment is Docker Compose: `romm` + `mariadb` + redis/valkey volumes, ~442 MB image, 3 services | docs.romm.app → Quick Start; hub.docker.com/r/rommapp/romm |
| **Not in nixpkgs, no `services.romm`** — NixOS path is `virtualisation.oci-containers` (podman backend is default) pulling `rommapp/romm` from Docker Hub | search.nixos.org (no hits); NixOS wiki Docker/Podman pages |
| Library layout: ONE library mount `/romm/library`, Structure A `roms/{platform}/` or B `{platform}/roms/`; platform folder names must map to RomM slugs via `system.platforms` in config.yml; **multiple library roots are not a documented feature** (`filesystem.roms_folder` is a single folder *name*) | docs.romm.app → Folder Structure; examples/config.example.yml |
| Curation: hidden games, manual/virtual collections, favorites, per-user controls | romm.app feature list + demo UI |
| License AGPL-3.0 | rommapp/romm LICENSE |

### 1.2 Decision criteria (score both options; Phase 0 fills the ☐ cells)

Score each 0–3 against the **7 goal capabilities** plus the operational
constraints. "C" = custom orchestrator; "R" = deploy & bend RomM.

| # | Criterion | Custom (C) | RomM (R) |
|---|---|---|---|
| 1 | DAT currency vs Fresh1G1R McLean 1G1R (goal 1) | build it (wget + schedule — already proven in `fetch-mclean-1g1r-dats.sh`) | **impossible** — RomM has no DAT concept (forfeit) |
| 2 | aria2 download management (goal 2) | build it (JSON-RPC client; `aria2-rpc.sh` semantics ported to Go) | **impossible** (forfeit; AriaNg stays as-is → two systems) |
| 3 | igir verify + organize (goal 3) | build it (exec igir, parse CSV report) | **impossible** (forfeit) |
| 4 | Metadata via existing Skyscraper pipeline (goal 4) | drive Skyscraper as-is; **reuses the on-pool resource cache** so ScreenScraper/TGDB quotas are untouched | RomM re-scrapes through its own stack → re-hits ScreenScraper with the same account, abandons the cache investment; RomM's scraper quality itself is good (ScreenScraper+Hasheous) — score partial |
| 5 | Launcher DB → `metadata.pegasus.txt` + `media/` (goal 5) | full control: our `jupiter-retroarch -L <core>` launch lines, our collections, our tree layout, atomic swaps | RomM 4.9+ can export `metadata.pegasus.txt` — **verify in Phase 0**: does the export emit per-system `launch:` lines we can control (config?), `directory:` compatible with our NFS layout, custom collections, and hide-flags? Unknown from docs; likely needs a fork. Score after experiment |
| 6 | Curation: hide/show + collections (goal 6) | build it (DB-backed, regenerates instantly) | native and polished — R wins this piece head-to-head unless we match it |
| 7 | Dashboard of all pipeline status (goal 7) | build it — includes download/verify/scrape state RomM cannot show | library stats only (no pipeline) |
| 8 | Kiosk compatibility (hard constraint) | kiosks unchanged (same dirs, same read-only NFS, same wrappers) | needs our 3-dataset tree (`games/{cartridge,optical,modern}` + `curated/exo-*`) squeezed into ONE library root via a symlink farm inside the container mount, platform-slug remapping in config.yml, and export shape control — **each item to verify experimentally** |
| 9 | NixOS/house fit | pure nix, zero containers on europa, builds from cache.nixos.org, no new flake input | first container runtime on europa; images pulled from Docker Hub at runtime (outside the nix closure); mariadb+redis daemons on a 2-core NAS |
| 10 | AGPL posture | our repo untouched by AGPL (we write no RomM-derived code) | unmodified container use: clean. Any bend = public fork, and **zero RomM code may be copied into jupiter-os**; orchestrating around it (our scripts calling its API) leaves TWO systems where today there are six |
| 11 | Single-system property ("one webapp runs the WHOLE pipeline") | yes | no — RomM covers 5–7 only; 1–4 remain scripts/systemd = the sprawl persists, now split across two UIs |
| 12 | Time-to-credible-UI (the bar) | the risk — we build the gallery ourselves | free (12k-star React SPA) |

**Preliminary recommendation (to be confirmed at the Phase 0 gate): CUSTOM.**
Rationale: criteria 1, 2, 3, 9, 11 are structural forfeits or house-rule
violations for RomM; RomM's wins (gallery polish, native curation, its
Pegasus export) are exactly the pieces we must beat anyway *because the critic
compares per piece* — and per-piece judging means RomM's forfeit pieces
(downloads, verify, DATs) are free wins for a competent custom build, while
its strong pieces (library, curation) we must win head-to-head regardless of
which backend serves them. Deploying RomM *and* keeping our pipeline = two
systems; deploying RomM *and bending it* = an AGPL fork of a 100k-line
Python/React codebase vs a ~5k-line Go app we fully own.

### 1.3 Phase 0 work items (all required before the gate)

1. **D1 matrix completion** — verify the ☐ cells with an experiment: run RomM
   5.1.0 in a throwaway NixOS VM (`virtualisation.oci-containers`, podman
   backend — the canonical method per NixOS wiki) with a fixture library; check
   (a) multi-root layout workarounds, (b) the actual shape of its Pegasus
   export (`launch:` lines, `directory:`, collections, hidden games),
   (c) what "bending" would cost concretely. **Never on europa.**
2. **D2 app placement** — default: **in-tree** `pkgs/arcade-webapp/` (source +
   templates), exposed as `packages.x86_64-linux.arcade-webapp`, consumed by
   `modules/services/arcade-webapp.nix` via `pkgs.callPackage` — the
   suno-backup/nom-web/dsh precedent; no new flake input, one atomic PR.
   Alternative (own repo + flake input, the suno-web precedent) only if the
   app grows a life outside this fleet.
3. **D3 database** — default: **SQLite** (single file under
   `/tank/archive/retro/state/`, WAL mode) via `modernc.org/sqlite` (pure Go,
   no cgo, substitutes cleanly). Single writer on a single host is SQLite's
   sweet spot. Postgres only if a concurrent-writer need appears (it won't on
   a 2-core NAS).
4. **D4 stack** — default: **Go stdlib `net/http` + `html/template` + htmx
   (one vendored JS file) + hand-rolled CSS**. No node, no SPA framework, no
   build step beyond `buildGoModule`. Precedent: suno-web (stdlib-only Go).
   Reversal trigger: if the critic rejects our gallery UI twice on polish
   grounds specifically attributable to server-rendering, escalate the front
   half to a vite/preact island layer built with `buildNpmPackage` (house
   already ships npm-built packages: ariang, dsh, aeon).
5. **ADR** — write `docs/adr/0002-arcade-webapp-architecture.md` recording D1
   verdict + D2/D3/D4 with evidence links. Coordinator locks it. No
   implementation of phases 1+ before the lock.
6. **Fixture corpus** (needed by every later phase) — `pkgs/arcade-webapp/testdata/`
   + `tests/fixtures/arcade/`: 3 hand-written Logiqx-format DATs (our own file
   hashes — we author the "ROMs", so they are 100% legal to commit) and a
   generator (Go test helper + `make fixture-arcade` target) producing
   deterministic dummy ROM files (NES/SNES/PSX-shaped names, fixed bytes).
   Gate: `igir copy test report` over the fixture is green with **zero
   unmatched**, asserted in a unit test.
7. **Progress page + scaffolding** — see §5; commit the empty-but-schema'd
   progress page and a stub `pkgs/arcade-webapp` that builds
   (`nix build .#arcade-webapp` green) so the loop has a ratchet from day one.

**Phase 0 exit:** D1–D4 decided with written evidence, ADR committed, fixture
igir-green, stub package building, `make check` + `make fmt-check` green.

---

## 2. Implementation phases, decomposed into gauntlet pieces

General rules for every piece:

- **Builder** implements; **critic** (fresh context, never the builder) does a
  blind A/B against RomM (demo.romm.app + repo) with labels stripped, names the
  *single biggest remaining gap*, and picks a winner. Loop builder→critic until
  the critic picks ours. Exit is the win, never a round count. Every verdict +
  named gap is logged in the progress page.
- **Ours must be populated with real-looking data** for the critic run: the
  library/curation pieces render against a dev fixture built from europa's real
  `metadata/skyscraper-cache` (a copied sample: real art + real game names;
  ROM *content* never leaves europa — names + art only).
- Every piece lands with: unit tests, `make check`/`make fmt-check` green,
  `nix build .#arcade-webapp` green, VM smoke green where applicable, one
  commit (+push), progress page updated.

### Phase 1 — Foundation + dashboard

**Piece P1 — Pipeline dashboard (goal 7).**
Build: `modules/services/arcade-webapp.nix`
(`jupiter.services.arcadeWebapp`: port, path options for every retro tree root,
sops secret *paths* only, catalogue from `jupiter.arcade.catalogue`,
hardened systemd unit, `RequiresMountsFor` the pool paths). Go app: scanner
that imports the catalogue TSV, walks `games/{cartridge,optical,modern}`,
`cache/incoming`, DAT dir (currency dates), existing
`state/inventory.json` (transition input), and the Skyscraper cache (coverage
numbers) into SQLite; dashboard page: per-system card wall (ROM count, size,
DAT date, verify state, art coverage %), download-queue summary, recent runs,
trends. Auto-refreshing (htmx polling).
*Wins blind vs RomM:* RomM's home shows library stats; it **cannot** show
download/verify/scrape/DAT-currency state at all — our dashboard must be
instantly legible (a stranger can answer "is the pipeline healthy?" in 5 s).
*Critic evidence:* two unlabeled dashboard screenshots on comparable data +
the one thing RomM's can express that ours can't (expect: none) and vice versa.

### Phase 2 — Pipeline control (the forfeit pieces — bank the wins)

**Piece P2 — Download control (goal 2).**
Build: aria2 JSON-RPC client in Go (secret read at runtime from the sops path —
never inlined, never logged; assert both in tests), per-system torrent submit
(same `dir=<incomingDir>/<sys>` + resume semantics as `jupiter-rom-acquire`),
queue view (progress, peers, ETA — parity with AriaNg for our use), pause/
resume/remove, and the *system-centric* view AriaNg lacks: per-catalogue-system
download state joined against verify state ("downloading / complete /
verified+promoted / needs re-verify").
*Wins blind vs RomM:* **RomM forfeits** — no acquisition anywhere. Ours still
must clear the absolute bar (≥ AriaNg usefulness, system-joined).
*Critic evidence:* screenshots of queue + system state machine; unit tests
against a mock aria2 RPC; VM test driving the real `aria2.service`.

**Piece P3 — Verify & organize (goals 1+3).**
Build: DAT manager (per-system fetch from Fresh1G1R on schedule + on demand;
date/version table), igir runner (exec with the tuned flags already proven in
`cartridge-verify.sh`: COPY promotion, `.aria2` in-flight skip, bucket routing
cartridge/optical/modern), report ingestion (igir CSV → DB: matched/unmatched/
missing per system), "re-verify" button, and the **zero-unmatched** indicator
per system.
*Wins blind vs RomM:* **forfeit** — RomM has no DAT/verify concept.
*Critic evidence:* fixture run: our UI showing an igir report with 0 unmatched
next to RomM's "scan" (which cannot express verification); automated: unit test
+ VM smoke assert `igir report` = 0 unmatched on the fixture tree.

**Piece P5 — Metadata engine control (goal 4).**
Build: Skyscraper driver in Go (exec `Skyscraper` with
`QT_QPA_PLATFORM=offscreen`, p7zip on PATH, creds via the existing sops secret
*paths* `screenscraper_creds`/`tgdb_apikey`, ScreenScraper primary + TGDB
onlymissing gap-fill — same strategy as `cartridge-scrape.sh`), schedule
(daily, replacing the `jupiter-rom-scrape` timer), per-game re-scrape, and the
**coverage tracker**: per-system metadata coverage % (title/desc/boxart/
screenshot/video separately) computed from the cache + generated files, with a
drill-down listing uncovered games.
*Wins blind vs RomM:* RomM has rich game-detail metadata but **no coverage
telemetry, no gap worklist, no scrape-queue control**. Our piece wins on the
operator story; the game-detail presentation belongs to P4.
*Critic evidence:* coverage dashboard + drill-down screenshots vs RomM's
metadata UI; unit test with a fake `Skyscraper` binary asserting argv +
coverage math; rate-limit guard test (credentials only ever read from paths;
quota-respecting "onlymissing" default asserted).

### Phase 3 — Library & curation (the head-to-head pieces — spend the loops here)

**Piece P4 — Library browsing.**
Build: gallery grid per system (real art from skyscraper-cache), global search,
filters (system/coverage/hidden/verified), game detail page (art carousel,
description, metadata table, file + verify state, per-game actions: hide,
re-scrape, re-verify, add-to-collection), deep-linkable routes, fast
server-rendered pagination (SQLite FTS for search).
*Wins blind vs RomM:* this is RomM's home turf — we win on **integration**
(every game row shows DAT-verified state, coverage, and pipeline actions RomM
cannot offer) *and* must not lose on polish: layout, art crops, loading,
keyboard navigation. Budget the most builder/critic loops here.
*Critic evidence:* same library (fixture names + real art) rendered in both,
labels stripped; the critic browses both (demo account + our VM/localhost) and
names the biggest gap each round.

**Piece P7 — Curation.**
Build: per-game hide/show (with bulk tools), custom collections editor
(name, ordering, membership), collections surface as first-class Pegasus
collections in the generated output (P6), instant "regenerate launcher DB"
action with before/after diff preview. Kiosks stay read-only consumers.
*Wins blind vs RomM:* RomM has native collections/hidden — parity is the
floor; we win on the **feedback loop**: an edit visibly lands in the served
launcher tree in seconds (RomM re-exports only on scan/manual API) and in a
diff the operator can audit.
*Critic evidence:* task-based comparison — "hide 3 games, build a
'Kitchen quick-play' collection, show me what the kiosk will see": ours
end-to-end vs RomM's flow; unit tests: hidden game excluded from generated
file, collection emitted as its own Pegasus block.

### Phase 4 — Launcher DB generation + kiosk cutover

**Piece P6 — Launcher DB generator (goal 5).**
Build: SQLite → `metadata.pegasus.txt` + `media/` per system (launch lines
`jupiter-retroarch -L <core> "{file.path}"` / `jupiter-cemu` for Wii U,
collections blocks, curation filters), written to a temp dir and **atomically
renamed** into the served tree (kiosks never see a half-written file),
generation-run log + strict self-validation (a full Pegasus-format parser we
own, run on every generation; output tree must be byte-stable for unchanged
DB state). Media referenced from the existing skyscraper-cache layout via
relative paths that resolve under the kiosk mount points (`game_dirs.txt`
reseeded per boot stays valid — **zero kiosk-side change**).
*Wins blind vs RomM:* RomM's Pegasus export cannot emit our kiosk-specific
launch lines/collections/tree (confirm in D1; if it can, this piece must win
on atomicity + validation + diffing instead).
*Critic evidence:* generated fixture tree diffed against today's
Skyscraper output (content-equivalent or better); parser test green; a
generated file opened next to RomM's export.

**Piece P8 — eXo integration + sprawl retirement (goals 5+7 wrap-up).**
Build: import the eXo curated collections into the DB (parse existing
`metadata.pegasus.txt` from `exo-to-pegasus.py` output — read-only; generation
for eXo stays kiosk-side initially, webapp owns browse/curation/coverage of
them), subsume `arcade-inventory` (webapp serves the inventory JSON endpoint
`make status-arcade` can read during transition), then retire on europa:
disable + remove `jupiter-rom-dats`/`jupiter-rom-acquire`/`jupiter-rom-verify`
oneshots, the `jupiter-rom-scrape` timer, and the `jupiter-arcade-inventory`
timer (move `scripts/cartridge-{verify,scrape}.sh`,
`fetch-mclean-1g1r-dats.sh` to `scripts/deprecated/` — precedent exists).
`aria2.service` + AriaNg **stay** (general-purpose daemon; the webapp is its
ROM-facing front end and links to AriaNg for non-arcade downloads).
*Wins blind vs RomM:* whole-pipeline coherence — one system, one UI; RomM
cannot absorb eXo + retire our units.
*Critic evidence:* before/after unit inventory on europa (systemctl list-units
diff), inventory endpoint parity test, eXo collections browsable+curated in UI.

### Phase 5 — End-to-end gauntlet + ship

Full-pipeline fixture run in the VM (DAT fetch stubbed → submit mock download →
verify → scrape (fake Skyscraper) → curate → generate → parse → launch-probe),
then the **measurable half** evidence (§4), final full-PR adversary audit,
completion verification gate, PR `arcade/webapp-gauntlet` → `main` with plan +
ADR + progress page linked, `CLAUDE.md`/`README` touched where the architecture
changed.

---

## 3. Acceptance criteria (testable, mapped)

| ID | Criterion (testable form) | Maps to |
|---|---|---|
| AC-1 | Webapp fetches each catalogue system's McLean 1G1R DAT from Fresh1G1R on schedule + on demand; per-system DAT date visible in UI. Test: unit (URL construction, parse) + VM smoke with stubbed URL; live fetch observed once on europa (coordinator-gated). | goal 1 |
| AC-2 | Submit/pause/resume/remove system torrents via aria2 JSON-RPC from the UI; queue state rendering < 2 s poll. Test: unit vs mock RPC + VM test against real `aria2.service`; grep-proof test that the RPC secret value never appears in logs/responses. | goal 2 |
| AC-3 | igir verify/promote runnable per system from the UI with report ingestion; on the committed fixture tree, `igir report` shows **zero unmatched** (automated unit + VM assertion). | goal 3 |
| AC-4 | Skyscraper runs driven by the webapp (ScreenScraper primary, TGDB gap-fill, creds via sops paths); per-system metadata coverage % tracked in DB and shown with a gap worklist; single-game re-scrape works. Test: unit with fake Skyscraper binary (argv + env assertions) + coverage math; live scrape observed once on europa. | goal 4 |
| AC-5 | SQLite DB is the source of truth; generator emits `metadata.pegasus.txt` + `media/` atomically; our strict Pegasus parser validates every generation; kiosk `game_dirs.txt` unchanged. Test: parser test + byte-stability test + atomicity test (kill -9 mid-generation leaves the previous tree intact). | goal 5 |
| AC-6 | Per-game hide/show + custom collections editable in UI and reflected in the next generation; hidden games excluded, collections emitted as Pegasus collection blocks. Test: generator unit tests on a curated fixture DB. | goal 6 |
| AC-7 | One dashboard shows download/verify/scrape/DAT/coverage/inventory state. Evidence: P1 critic win recorded in progress page. | goal 7 |
| AC-8 | **Measurable half:** (a) fixture served tree igir-verified zero-unmatched [automated]; (b) metadata coverage % tracked and rendered [automated]; (c) a game **actually launches** from pipeline output: Tier-1 automated probe (execute the exact generated `launch:` string in a VM where `jupiter-retroarch` is a probe wrapper asserting argv + core + resolvable ROM path) + Tier-2 live observation on one kiosk (amalthea) with coordinator approval. | the bar |
| AC-9 | House rules: `make check` green, `make fmt-check` clean, no unjustified flake inputs (target: **zero** new), module style (`jupiter.services.arcadeWebapp`, explicit mkOption/mkIf/types, `{ config, lib, pkgs, ... }`), no global stdenv overlays, secrets activation/runtime-time only, everything substitutable from cache.nixos.org. | CLAUDE.md |
| AC-10 | **Gauntlet exit:** every piece P1–P8 has a recorded critic verdict "ours" in the progress page (with the final named-gap=null or accepted-residual note); exit is the wins, not a round count. | gauntlet |

---

## 4. Verification strategy per phase

Standing checks after every commit (cheap, eval/build-level — house discipline):

```bash
make fmt                       # nixfmt-rfc-style
make fmt-check
nix build .#arcade-webapp      # the app package builds standalone (untuned legacyPackages)
(cd pkgs/arcade-webapp && go test ./...)   # unit + fixture tests, no network
make check                     # nix flake check --no-build — every host still evals
```

| Phase | Additional verification |
|---|---|
| 0 | D1 RomM experiment in a **throwaway NixOS VM** (`virtualisation.oci-containers`, podman) — never europa; ADR review; fixture gate: `igir copy test report` on fixture = zero unmatched (unit-tested) |
| 1 | New `make test-arcade-webapp`: `nixos-rebuild build-vm` on a new minimal test host `tests/hosts/arcade-webapp-vm.nix` (imports the module, path options → VM-local fixture dirs, sops-path options → plain temp files); in-VM script: service up, endpoints answer, scanner import counts match fixture, dashboard renders |
| 2 | P2: unit vs mock aria2 RPC; extend the VM test to enable `jupiter.services.aria2` and drive a real submit/pause. P3: fixture igir zero-unmatched asserted in VM. P5: fake-Skyscraper unit tests (argv, env, offscreen, p7zip PATH, onlymissing default) |
| 3 | Screenshot protocol: ours (VM or localhost, real-cache-derived fixture data) vs demo.romm.app, labels stripped, fresh-context critic; UI smoke tests (httptest over the real template stack) for search/filter/detail routes |
| 4 | Generator: parser + byte-stability + atomicity + diff-vs-Skyscraper tests; **launch-probe test** (Tier-1, AC-8c); europa cutover is a coordinator-gated live deploy: `ssh root@europa` → `nixos-rebuild switch --flake github:belikh/jupiter-os#europa` → observe: webapp serves, units gone (`systemctl list-units 'jupiter-rom-*' 'jupiter-arcade-*'`), kiosk still boots into Pegasus with regenerated tree; Tier-2: launch a game on amalthea, record it |
| 5 | End-to-end VM pipeline run (AC-8a/8b/8c-Tier1); full-PR adversary audit + reconciliation; completion gate records pass/fail/blocked per AC (open-ultracode verification records); PR to main |

Live-deploy rule: VM tests and eval-level checks are the default; **any live
switch on europa/kiosks asks the coordinator first** (house rule).

---

## 5. Risks & assumptions

### Risks

| ID | Risk | Mitigation |
|---|---|---|
| R1 | Losing the head-to-head UI pieces (P4/P7) to RomM's polish | Real art from day one; htmx interactivity + strict design budget; escalation path D4 (islands via buildNpmPackage) if rejected twice on framework grounds; loops concentrate here |
| R2 | ScreenScraper/TGDB rate limits re-hit | Never re-scrape what the Skyscraper cache already holds (drive Skyscraper's cache-first flow); onlymissing default; per-run quota guard in the driver |
| R3 | AGPL contamination | Zero RomM code in this repo, ever; if D1 somehow flips to RomM, it runs unmodified in a container and our repo only ever references its API; any fork lives in its own public repo |
| R4 | RomM's folder/model conventions vs our ZFS layout | Moot if custom wins; if RomM wins D1, the symlink-farm + slug-mapping + export-shape costs are part of the scored matrix, not an afterthought |
| R5 | europa is a 2-core HDD box | Webapp serializes pipeline jobs (internal queue: one igir XOR one scrape XOR one generation); scans incremental; heavy walks stay on the hourly-equivalent cadence inventory already proved safe |
| R6 | QEMU kiosk-launch test infeasible (Pegasus is a GUI) | Two-tier AC-8c: automated launch-probe (no display needed) + one coordinator-gated live kiosk observation; don't fake it |
| R7 | Fixture realism | Fixtures carry real game *names* + real *art* (copied cache sample) with dummy content — UI and pipeline logic testable without TB-scale data |
| R8 | Kiosk NFS read-only vs atomic generation | tmp+rename on the europa side; media via relative paths under existing mount points; byte-stable output so kiosk re-reads are cheap |
| R9 | Branch drift from main | Rebase onto main at every phase gate; CI (fmt/check) green on the branch throughout |
| R10 | secrets handling (house-critical) | Secrets referenced by sops *name/path* only, read at runtime; tests assert values never appear in logs/env dumps; no secret ever in a committed file |

### Assumptions

- A1: europa remains the pipeline host; its paths/datasets stay as inventoried.
- A2: Kiosks stay read-only NFS Pegasus clients with **zero** client-side change
  (game_dirs reseed per boot already picks up regenerated metadata).
- A3: `scripts/cartridge-catalogue.tsv` stays the source of truth for *system
  facts* (the webapp imports it via `jupiter.arcade.catalogue`); the DB is the
  source of truth only for *per-game/run state* — no second hand-copied maps
  (the repo's own drift history is the warning).
- A4: SQLite/single-writer is sufficient (no concurrent multi-writer need).
- A5: RomM demo.romm.app stays reachable for critics; screenshots permitted.
- A6: ScreenScraper/TGDB creds + aria2 secret remain valid in sops under their
  existing names.
- A7: Fresh1G1R remains fetchable at the URLs `fetch-mclean-1g1r-dats.sh` uses.
- A8: DATs/torrents/ROMs/media stay **on-pool only** (ADR-0001 boundary rule);
  our fixture DAT/ROMs are self-authored and legal to commit.

---

## 6. Role sequence & the live progress page

### Open-ultracode role sequence

1. **Coordinator** — intake (done by this plan), phase gates, approves any live
   deploy, owns final status. Locks the Phase 0 ADR before Phase 1.
2. **Planner** — this document; revises at phase gates if evidence contradicts.
3. Per piece P1…P8 (gauntlet core):
   - **Implementer** — RED/GREEN: failing fixture/VM test first, smallest
     passing change, records evidence.
   - **Adversary** — structured review (finding ID / severity / confidence /
     evidence / disposition) on the diff: missing tests, secret leaks, module
     style, buildability-rule violations, spec drift.
   - **Reconciler** — accept/fix/reject each finding with rationale; high/medium
     unresolved block the critic run.
   - **Verifier** — fresh `make check` / `go test` / `nix build` / VM smoke;
     records pass/fail/blocked per check (open-ultracode verification records).
   - **Builder→Critic loop** — builder iterates the piece; a **fresh-context
     critic** does the blind A/B vs RomM (labels stripped, comparable data),
     names the single biggest gap, picks a winner; repeat until ours wins;
     log every round in the progress page.
4. **Final** — full-PR Adversary audit → Reconciler → Verifier completion gate
   (all ACs evidenced; blocked/skipped never reported as done) → fable-judge
   style "did it actually work" pass on the measurable half → PR to main.

Fallback: if subagent fan-out is unavailable, the same roles run sequentially
in-session with labeled role sections (open-ultracode single-session fallback);
the critic still gets fresh context (new session or context reset).

### Live progress page

- **Lives at:** `docs/plans/arcade-webapp-gauntlet-progress.md` in this repo
  (GitHub renders it; linked from the PR description). Screenshots under
  `docs/plans/arcade-webapp-gauntlet/`. Committed + pushed at **every** piece
  boundary and every critic verdict — the page *is* the loop's heartbeat.
- **Contains (fixed schema):**
  - Header: current phase, branch, ADR link, last update timestamp.
  - Piece table: `piece | state (building/review/critic-loop/won/blocked) |
    builder loops | last critic verdict | critic's named gap | evidence link`.
  - Per-phase verification log: command → pass/fail/blocked (mirrors the
    open-ultracode verification records).
  - Decision log: D1–D4 verdicts + evidence links; any plan amendments.
  - Gauntlet scoreboard: pieces won vs remaining (exit = all won).
