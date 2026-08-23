# Arcade Webapp Gauntlet — Progress

The live heartbeat of the builder/critic loop driving
[the plan](arcade-webapp-gauntlet.md). Updated at every piece boundary and
every critic verdict. Screenshots (when they exist) land under
`arcade-webapp-gauntlet/` next to this file.

- **Phase:** 2-4 complete — **P1–P7 won** (blind critics) · P8 in progress
- **Branch:** `arcade/webapp-gauntlet`
- **ADR:** [ADR-0002 — custom, not RomM](../adr/0002-arcade-webapp-custom-vs-romm.md)
  (D1 research-confirmed 2026-08-21; D2–D4 accepted)
- **Last update:** 2026-08-23 17:55 AEST

## Piece table

| Piece | State | Builder loops | Last critic verdict | Critic's named gap | Evidence |
|---|---|---|---|---|---|
| P1 — Pipeline dashboard | **won** | 1 (0 rebuilds) | **ours** (blind, labels stripped; DOM A/B, data-scale asymmetry disclosed+discounted) | download stage has no surface (queue depth/active/errored/throughput) — folds into P2; meters lack `role="progressbar"`/`aria-valuenow`, polling regions lack `aria-live` (carry to P2) | `p1-ours-desktop.png`, `p1-ours-mobile.png`, `p1-bar-desktop.png`; critic: "B answers the 5-second question in one strip… A contains zero pipeline vocabulary — verify 0, torrent 0, scan 0, coverage 0" |
| P2 — Download control | **won** | 1 (0 rebuilds) + adversarial reconciliation | **ours** (blind, labels stripped; A=AriaNg's literal list-view template extracted from its shipped JS bundle, B=ours rendering a live aria2d queue: 2 active 64 MiB, 1 paused, 3 completed) | acquire column is a dead end when the torrent is missing — no stage/paste/trigger control on-page (carried to P3) | `p2-ours-downloads.html`, `p2-bar-ariang-list-template.html`, `p2-ours-{desktop,mobile}.png`; critic: "B understands the job is a collection pipeline, not a file list… A manages the daemon, not the collection"; implementation commits `f883582`/`ad361c2`/`b8f8315`/`f0b29b2`, review fixes `4be90e9`/`dfa680b` |
| P3 — Verify & organize | **won** — 1 loop + adversarial reconciliation | 1 (real-igir bring-up: 3 root-caused VM failures, 0 masked) + adversarial review pending | **ours** (blind; A=RomM demo DOM, B=our /verify page with a real igir run — snes/gb green, nes red-unmatched, segacd unknown) | unmatched files not drillable in-page + no run history w/ deltas (carry to P4) | commits `ca09507` (Go half) + `b1809bc`/`ce84fde` (real-igir refinements + wiring); VM smoke 27 steps green ×2 consecutive incl. REAL igir amber-extra → green zero-unmatched on a fresh promotion (log excerpt in the Phase 3 verification section); `p3-ours-verify.html`, `p3-ours-verify.png` |
| P4 — Library browsing | **won** — 1 loop + adversarial micro-audits | 1 (2 VM bring-up failures, both root-caused: pagination + missing awk) | **ours** (blind; A=anonymized RomM gallery home DOM, B=our /library grid + detail over the fixture store w/ generated SVG posters) | detail lacks CRC/SHA1 checksum rows + persistent report link (carry to P5) | `p4-ours-library.html`, `p4-ours-detail.html`, `p4-ours-library.png`, `p4-bar-romm-gallery.html`; critic: "findability exists only in B — A's home has zero input/select elements… B puts verification state on every card" |
| P5 — Metadata engine control | **won** — 1 loop + adversarial reconciliation (2 HIGH fixed incl cache-key drift + secret-tail redaction) | 1 (VM bring-up runs 1–2 clean after the stub argv-journal fix, per `bb465d5`; post-push runs 3–4 flaked TEST-side races → completion-gated + slot-free wait in `108beae`, final PASS fresh below) | **ours** (blind; A=anonymized RomM home DOM + its published metadata docs — deep pages don't render headless, B=our /metadata + game detail after a real igir verify) | scrape run-history/deltas not visible post-run + no hash value displayed on detail (carry to P6) | commits `c94be34` (shared cache parser/CacheID/ApplyCacheFlags) `f01bcc3` `2663eb7` `ccb057f` (/metadata UI, serialized Driver) `449cd97` (module wiring) `bb465d5` (stubbed-Skyscraper smoke) + hardening `108beae`; reconciliation `0722aa7`…`c9241fc`; VM smoke: nes desc/cover 0→100 through the real driver→store→ApplyCacheFlags stack; `p5-ours-metadata.html`, `p5-ours-detail.html`, `p5-bar-romm-metadata-docs.html`; critic: "B renders a real per-system table… A's library DOM contains zero rendered content" |
| P6 — Launcher DB generator | **won** — 1 loop + adversarial reconciliation (2 MED fixed: second-truncation test flake root-caused to store pruning precision; crash-window temp residue sweep) | 1 (VM bring-up: 1 root-caused igir-semantics regression + 3 smoke-side defects, 0 masked; 7 VM runs) + adversarial reconciliation | **ours** (blind; A=anonymized RomM pegasus_exporter.py source, B=our real generated metadata files for nes+snes) | enrichment not demonstrated end-to-end (no description/assets lines from scraped data in evidence) — carry to P7/P8 e2e | commits `2c6c70f` `ea841ac` `a3b20c7` `91b3dc6` `61e2ec0` `6ff8479`; two consecutive clean PASSes (runs 6+7) with the P6 block: launch line + relative paths + byte-stability + strict-parser validation + hidden exclusion both ways + pending split; reconciliation `2d62bdd` `1a2f4b0` `92f4a50` `545cee4`, fresh `-count=5 -race` all-green (below); `p6-ours-generated/`, `p6-bar-exporter-source.py`; critic: "only B has it: launch: … A's exporter never emits a launch: field anywhere… every entry is unbootable shelf decoration" |
| P7 — Curation | **won** — 1 loop + adversarial reconciliation (2 HIGH fixed: derived-shortname collision could brick a system's regeneration while UI said success — now probed at create/rename with visible 409; regen options snapshot raced the lock and could overwrite fresh bytes with stale — snapshot moved inside GenerateFresh(provider)) | 1 (5 VM runs: 2 smoke-side assertion defects root-caused incl. a grep-BRE trap, then 3 consecutive clean PASSes) + adversarial reconciliation | **ours** (blind; A=anonymized RomM collections model+endpoints source, B=our real /collections+editor DOM + generated nes/snes files carrying the cross-system "Kitchen quick-play" block per-console cores) | no hidden/pending status chip on collection member rows; count honesty ("3 tracked / 2 playable") — carry to P8 | `p7-ours-curation/`, `p7-romm-model.py`, `p7-romm-endpoints.py`; critic: "A curates only an authenticated web API — nothing in its model or endpoints emits a launcher file" |
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

### Phase 2 (P2 — download control)

Builder loop 1. All fresh on the committed tree (`f883582` client →
`ad361c2` UI → `b8f8315` module+VM → `f0b29b2` VM debuggability).

| Command | Result | Notes |
|---|---|---|
| `go test -count=1 ./...` (in `pkgs/arcade-webapp`) | **pass** (2026-08-21) | new suite `internal/aria2` (12 tests vs a mock JSON-RPC endpoint): token-first auth on every method, aria2's string-encoded numbers, the load-bearing EMPTY uris array on addTorrent (#2075), check-integrity driven by `.aria2` control-file presence, JSON-RPC error = hard result never retried, transport-only submit retries with backoff, typed unreachable + timeout + malformed-body errors, and **TestSecretNeverLogged** — every log line of a client run covering all methods plus the unreachable / HTTP-500 / malformed-body / JSON-RPC-error failure modes is grepped for the secret while the mock proves the token WAS sent (non-vacuous); the timeout path is covered separately by TestQueryTimeoutBoundsCall, which asserts the typed deadline error but does not grep logs (deadline-expiry errors carry only the ctx error string — no secret can enter them, as the token exists solely inside the request body). `internal/web` grows the downloads suite: page/fragment shape, 2s-poll + `aria-live` + `role="progressbar"`/`aria-valuenow` markers, summary fragment incl. unreachable → 200-state-not-500, nil-client "not configured", acquire wire shape (dir routing + seed-time=0 + allow-overwrite + check-integrity) + audit-run recording + all failure modes (code-12 duplicate → ok-with-note, other codes → surfaced error), pause/resume/remove daemon calls, X-HX-Request CSRF on every mutating endpoint (incl. `/rescan`), the join state machine over fixture store data (active/waiting/errored aggregation, aggregate %, torrent availability, non-arcade downloads never attribute, idle collapse), button-visibility matrix, dir-attribution boundaries, queue-truncation hints, partial-batch hint, acquire-503-when-unconfigured |
| `nix build .#arcade-webapp` | **pass** (2026-08-21) | no vendorHash change (the aria2 package is stdlib-only; everything committed before the FOD ran — the D-P1e rule). Binary smoke: starts, logs secret-presence paths, fatal-exits on missing catalogue env as designed |
| `make test-arcade-webapp` | **pass** (2026-08-21, 5 runs: 3 consecutive + mutation + final) | the VM now runs a REAL aria2 daemon (minimal local-secret config — `jupiter.services.aria2` itself would drag nginx/AriaNg/sops into the sops-free test host). The smoke drives the whole P2 cycle through the webapp: aria2 reachable chip → `POST /systems/nes/acquire` 202 → download appears in the queue fragment **attributed to nes** → pause → `data-status="paused"` → resume → **complete**, payload verified at `incoming/nes/vm-fixture-payload.bin` = 2097152 B → `acquire` run in the runs table → **journal grep: secret value never logged**. Determinism: the download is a self-authored torrent (mktorrent, private, single webseed) fed by an in-VM darkhttpd, throttled to 256 KiB/s so the 2 MiB payload stays in flight long enough to pause; ~41–44 s wall per run (well under the ~90 s budget). Mutation proof: payload-size assertion broken on purpose → explicit `ARCADE-WEBAPP-VM: FAIL` marker + make exit 1 (fail-fast verdict channel intact) |
| `make fixture-arcade` | **pass** (2026-08-21) | igir gate still green post-P2: nes 5/5, snes 4/4, gb 4/4 FOUND, **0 unmatched** |
| `make fmt` then `make fmt-check` | **pass** (2026-08-21) | clean, no diff |
| `make check` | **pass** (2026-08-21) | every host evals incl. the VM host with the new options/services |

**P1-critic carries landed with P2:** every meter (P1 coverage meters
included) now carries `role="progressbar"` + `aria-valuenow` (+
`aria-valuemin/max`, label); every polled region is `aria-live="polite"`
with `role="region"` + label; the two pages get a nav with
`aria-current`. RED proof: `git show HEAD:pkgs/.../partial_systems.html
| grep -c role="progressbar"` → 0 at the P1 boundary. The unit render
test asserts two distinct meter values (`aria-valuenow="60"` for nes,
`aria-valuenow="0"` for gb) + `aria-live`; the 100 % case is asserted
only in the VM test's card wall (`data-coverage="100"` on snes), not by
a unit test.

**Deviation from the letter of the plan, logged as D-P2a:** the VM test
was specified as "download a small local file via http URL"; it instead
submits a self-authored **torrent with an HTTP webseed** pointing at the
in-VM static server — strictly stronger coverage (it exercises the REAL
acquire path: catalogue torrent basename → `addTorrent` with
aria2-rpc.sh's option shape → dir routing → BT resume semantics) while
using no real torrents and no trackers/DHT (private flag). Pause/resume
specifically requires the webseed server to answer HTTP Range —
darkhttpd does, python's `http.server` does not (resumed download stalls
forever; verified locally before wiring).

### Phase 2 adversarial review — reconciliation (2026-08-21)

Verdict **FIX**; 7 findings: **6 fixed** (`4be90e9` code, `dfa680b` VM+module,
this commit for the two wording items), **1 accepted as residual**, none
rejected. Piece stays in `review` until the blind critic.

| Finding | Disposition | What changed |
|---|---|---|
| ADV-P2-01 MED (gating) — VM secret grep could pass vacuously (dead journal → `grep -c` prints 0, `\|\| true` swallows journalctl failure) | **fixed** (`dfa680b`) | the check now two-guards itself: journalctl must succeed AND the journal must contain the unit's stable startup line (`arcade-webapp: listening on`, emitted right before ListenAndServe). Mutation re-proof: journal capture scratch-emptied → `ARCADE-WEBAPP-VM: FAIL: webapp journal lacks its startup line — journal capture broken (secret grep would be vacuous)` + make exit 1; restored → clean PASS ("journal alive: startup line present, grep clean") |
| ADV-P2-02 LOW — capped tellWaiting/tellStopped hid overflow without a hint | **fixed** (`4be90e9`) | fetchDownloads diffs each successful fetch against GlobalStat's counts; the fragment renders "+N more waiting/stopped downloads not shown". Computed only on successful fetches (a failed fetch is a partial, not a truncation). RED→GREEN TestQueueTruncationHint (+148/+60, and no hint within caps) |
| ADV-P2-03 LOW — (a) tell* failures discarded → confidently short queue; (b) acquire 202 vs dlControl 503 for not-configured | **fixed** (`4be90e9`) | (a) any tell* failure (or shared-ctx expiry) marks the VM `Partial` → `data-partial="true"` + "partial queue — … may be incomplete" hint, distinct from unreachable (stat/version answered = daemon up); (b) acquire answers 503 when unconfigured, consistent with dlControl. RED→GREEN TestPartialQueueHint, TestAcquireNotConfiguredIs503 |
| ADV-P2-04 LOW — ambiguous addTorrent timeout retried → code-12 duplicate-infohash reported as failure although the download registered | **fixed** (`4be90e9`) | `aria2.IsAlreadyRegistered` (code 12) on submit = success-with-existing-download: run recorded ok with an "already registered" note, no error surfaced — the same idempotent-rerun semantics jupiter-rom-acquire relies on. Genuine rejections (other codes) still surface + record error runs. RED→GREEN TestAcquireDuplicateIsSuccess; the rejection case of TestAcquireFailureModes now uses code 1 |
| ADV-P2-05 LOW — torrentDir missing from poolPaths/RequiresMountsFor | **fixed** (`dfa680b`) | added (transitively covered on europa today; the ordering intent is per-path and the downloads page stats it at render time) |
| ADV-P2-06 LOW — Phase-2 wording overclaims (a) "pins all three coverage meters" (b) "every failure mode" grepped | **fixed** (this commit) | (a) now states exactly: the unit test asserts two distinct meter values (60, 0); the 100 % case is VM-only (`data-coverage="100"`); (b) now states exactly: the inline grep covers all methods + the unreachable/500/malformed/JSON-RPC-error modes; the timeout path is covered by TestQueryTimeoutBoundsCall, which asserts the typed deadline error but does not grep logs |
| ADV-P2-07 — 2 s queue poll cost on the LAN | **accepted (residual)** | parity with AriaNg's 1 s default (we poll half as often); browsers throttle htmx timers in hidden tabs, and the fragment degrades to a static state when unreachable — the poll never multiplies under failure. Revisit only if the critic flags interactivity lag |

### Phase 3 adversarial review — reconciliation (2026-08-22)

| Finding | Disposition |
|---|---|
| ADV-P3-01 vacuous companion assertion | **fixed** — VM smoke asserts aria2's `<infohash>.torrent` sidecar exists in incoming/nes before the amber-extra step; --input-exclude coverage cannot pass vacuously |
| ADV-P3-02 stale green pill on parse failure | **fixed** — verify pill shows a "last attempt failed" hint when the most recent verify run errored |
| ADV-P3-03 relative input roots re-arm glob crawl | **fixed** — Runner construction fatals loudly on non-absolute roots |
| ADV-P3-04 stage-torrent symlink follow | **fixed** — writes use O_CREATE\|O_EXCL\|O_NOFOLLOW; pre-planted symlinks fail loudly |
| ADV-P3-05 copyTree skips non-regular files vs rsync -a | **accepted** — safer direction; documented divergence from cartridge-verify.sh |
| ADV-P3-06 stage-uri LAN-trust posture | **accepted** — same no-auth LAN class as ADV-P1-07/08 |

Post-review verification (fresh): `go build/vet/test -count=1 ./...` pass · `nix build .#arcade-webapp` pass · `make test-arcade-webapp` pass · `make fixture-arcade` pass · `make fmt-check` pass · `make check` pass (transient nix evaluator segfault on packages.dsh, clean on re-run).

### Phase 2 post-review verification (fresh, on the reconciled tree)

| Command | Result | Notes |
|---|---|---|
| `go test -count=1 ./...` (in `pkgs/arcade-webapp`) | **pass** (2026-08-21) | 6 packages; 4 new RED→GREEN tests (truncation, partial, 503-consistency, code-12-success) + the split rejection case; no existing assertion weakened |
| `make test-arcade-webapp` | **pass** (2026-08-21) | ADV-P2-01 mutation run: dead-journal scratch mutation → explicit FAIL marker + make exit 1 (fail-fast at the check, no timeout burn); restored → clean PASS, final line "RPC secret never logged (journal alive: startup line present, grep clean)" |
| `nix build .#arcade-webapp` | **pass** (2026-08-21) | no vendorHash change (stdlib-only edits) |
| `make fixture-arcade` | **pass** (2026-08-21) | igir gate still zero-unmatched (nes 5/5, snes 4/4, gb 4/4) |
| `make fmt` then `make fmt-check` | **pass** (2026-08-21) | clean, no diff |
| `make check` | **pass** (2026-08-21) | every host evals incl. the VM host with torrentDir in RequiresMountsFor |

### Phase 3 (P3 — verify & organize + DAT currency)

Builder loop 1 on `ca09507` (committed Go half) + the working-tree
refinements, now committed as `b1809bc` (real-igir semantics) +
`ce84fde` (module/VM wiring). Bring-up ran the VM **8 times**: 5
failures, each chased to root cause (never masked), then 2 consecutive
clean PASSes on the final config + 1 earlier flake class hardened
against. Full detail:

| Command | Result | Notes |
|---|---|---|
| `go build ./... && go vet ./...` (in `pkgs/arcade-webapp`) | **pass** (2026-08-22) | gofmt also clean (4 files the uncommitted session left unaligned were `gofmt -w`'d — whitespace only) |
| `go test -count=1 ./...` (in `pkgs/arcade-webapp`) | **pass** (2026-08-22, after fixes) | new since ca09507: `TestParseReportProvenance` (input/output × UNUSED/DUPLICATE + neither-side→Other), `TestMigrateV2DatabaseStepsToV3`, `TestDATRefreshAllSurvivesHandlerReturn` (real `httptest.NewServer` — recorder contexts are never cancelled, so they cannot see the handler-return cancellation bug), re-verify-echo-stays-green + amber-extra pills through the real templates, argv pin updated to the input-anchored exclude |
| `nix build .#arcade-webapp` | **pass** (2026-08-22) | no vendorHash change (stdlib-only edits since ca09507 — the D-P1e rule held); binary smoke: starts, logs secret-presence paths |
| `make test-arcade-webapp` | **pass** (2026-08-22, runs 7+8: 2 consecutive on the final config) | all 27 smoke steps: P1 dashboard → P2 download cycle (pause/resume/complete, secret grep) → P3: worklist + CSRF matrix (5 new endpoints), stubbed DAT refresh (currency date 2026-08-21→22 rendered, dat-fetch run recorded), unmapped wiiu surfaces its mapping error, `.aria2` whole-system skip (no report written), **REAL igir** nes verify amber `2 extra` (zips in the tree — provenance split live) → tree aligned + output emptied → **green zero-unmatched with the promotion files physically written by igir**, dashboard card flips verified, a2600 promote-unchecked, verify-all green (nes idempotent under re-verify echoes), stage-torrent under the catalogue name (acquire goes live; `.sh`→400, unknown system→404), stage-uri magnet queued / ftp→400 |
| `make fixture-arcade` | **pass** (2026-08-22) | igir gate still zero-unmatched (nes 5/5, snes 4/4, gb 4/4 FOUND) — the corpus DATs/ROMs untouched by the VM changes |
| `make fmt` then `make fmt-check` | **pass** (2026-08-22) | clean, no diff |
| `make check` | **pass** (2026-08-22) | every host evals incl. the VM host with the new P3 options/services |

**Bring-up failure log (each root-caused, none masked):**

1. **Run 1 — `1 unmatched`, never amber:** the REAL aria2 writes an
   infohash-named `.torrent` into every download dir even via
   `addTorrent` (disproven docs claim magnet-only; proven with a local
   daemon + `aria2.addTorrent` reproduction). The companion surfaced as
   input-side UNUSED → red. Fix: `--input-exclude` (D-P3e) — the
   served CSV now literally carries zero unmatched rows for them.
2. **Run 2 — no report at all:** the first exclude attempt used a bare
   `**/*.torrent`, which igir expands against the filesystem from the
   **process cwd** — as root under cwd=/ it crawled the entire nix
   store for minutes (hang). Diagnosed by the added `ps` hang-check in
   the smoke's DEBUG block; proven locally (`EACCES: scandir '/root'`
   as a normal user from cwd=/). Fix: anchor the glob to the absolute
   input dir (`<input>/**/*.torrent`) — bounded walk, exclusion still
   proven effective. Also fixed the runner's silent parse-failure
   early return (no journal trace — cost the blind debug round).
3. **Run 3 — silent 300 s burn at the aria2-wait step (flake class):**
   the daemon stalled mid-startup once; the smoke's unbounded curls
   turned it into a silent full-budget timeout with no FAIL marker
   (ADV-P1-04's lesson in a new costume). Fix: `--max-time 10` on every
   smoke curl + stall diagnostics every 20 misses + driver timeout
   300→480 s (real igir is node). Did not recur in runs 4–8.
4. **Run 5 — igir hang confirmed** (the `ps` DEBUG caught the crawling
   node process with the bare glob in argv) — same root cause as 2.
5. **Run 6 — `dat-fetch` audit grep failed:** the status partial
   renders only the newest 8 runs; P3's verify runs + post-verify
   rescans pushed the early dat-fetch row out of the window before the
   grep. Fix: assert each run kind at the step that records it (the
    assertion moved into the DAT-refresh block; documented in the smoke).

### Phase 4 (P4 — library browsing: module wiring + VM smoke)

Builder loop 1 on the committed Go half (`/library`, `/partials/library`,
`GET /systems/<sys>/games/<id>`, `GET /art/<sys>/<id>` with SVG-poster
fallback): the fleet-module wiring (`artDir` option →
`ARCADE_WEBAPP_ART_DIR` when set, RequiresMountsFor + ReadOnlyPaths join)
and the VM smoke steps. 2 VM bring-up failures, both root-caused, then
clean PASS:

1. **Run 1 — "library page missing Starlit Vault":** assumed the fixture
   title renders on page 1 — the gallery paginates at `libPageSize`=10
   and the 16-game corpus sorts it onto page 2. Assertions retargeted to
   what page 1 honestly carries (early titles + `rel="next"` pager);
   Starlit Vault is reached through its own `?q=` filter step.
2. **Run 2 — `awk: command not found`:** the card-href↔title pairing
   needs awk; the smoke unit's `path` didn't carry it (silent empty
   capture). Fix: `gawk` added to the unit path.
3. **Run 3 latent bug caught by the same failure:** the title anchor
   pattern expected `title="Starlit Vault"` — rendered titles keep their
   region tags (`Starlit Vault (USA)`, extension stripped only), so the
   closing quote never matched. Pattern loosened; run 3 green.

| Command | Result | Notes |
|---|---|---|
| `go build ./... && go vet ./... && go test -count=1 ./...` (in `pkgs/arcade-webapp`) | **pass** (2026-08-22) | no Go changes this piece — all suites green on the tree as found |
| `make test-arcade-webapp` | **pass** (2026-08-22, 3 runs incl. final) | new smoke steps: `/library` 200 with page-1 fixture card + `rel="next"` pager + cards wired to `/art`; filtered `?q=Starlit` keeps its match and excludes Mecha Garden; detail page via the card's OWN href (autoincrement id never assumed) → 200 + `<code>rel_path</code>` fact (`Starlit Vault (USA).nes`); `/art/nes/<id>` serves `image/svg+xml` (artDir unset = fallback path under test) with an `<svg>` body |
| `make check` | **pass** (2026-08-22) | every host evals incl. the VM host with the new option wired (unset — null default branch) |
| `make fmt` then `make fmt-check` | **pass** (2026-08-22) | clean, only the two touched files modified |

### Phase 5 (P5 — metadata engine control)

Builder loop 1 across seven commits: `c94be34` shared cache parser +
CacheID + ApplyCacheFlags → `f01bcc3` igir ingest crc32/sha1 →
`2663eb7` cartridge-scrape.sh two-phase port → `ccb057f` /metadata UI +
Driver-owned serialization → `449cd97` module wiring (skyscraperPackage,
scrapeIntervalHours, writable cache) → `bb465d5` stubbed-Skyscraper VM
smoke → `108beae` post-push flake hardening (the interrupted unit,
finished and committed — see D-P5a). Smoke runs 1–2 passed after the
stub argv-journal fix; runs 3–4 flaked on TEST-side races only, fixed
in `108beae`, then a fresh clean PASS on the final tree:

| Command | Result | Notes |
|---|---|---|
| `go build ./... && go vet ./... && go test -count=1 ./...` (in `pkgs/arcade-webapp`) | **pass** (2026-08-22, on the hardening tree) | 9 packages green incl. `internal/scrape` (Driver-owned mutex serialization, ErrBusy, outcome-classifying scrape) and the web metadata suite (render/CSRF/503-unconfigured/409-busy/gated-batch coverage-flip/game-windowing/history-delta over a gated fake Skyscraper) |
| `make test-arcade-webapp` | **pass** (2026-08-22) | full smoke incl. the P5 block: worklist + fragment shape + pre-scrape 0% truth, CSRF matrix over 3 new endpoints, per-system scrape → nes desc/cover 0→100 via the stub writing sha1-keyed db.xml, scrape run asserted at its own step, run-history drill-down, scrape-all gated on batch COMPLETION AND gb flip, dashboard card agrees, game re-scrape proven windowed via the stub argv journal |
| `make check` | **pass** (2026-08-22) | every host evals incl. `arcade-webapp-vm` with skyscraperPackage=stub, writable materialized cache dir, scrapeIntervalHours=null |
| `make fmt` then `make fmt-check` | **pass** (2026-08-22) | fmt rewrote nothing beyond the two intended files; fmt-check silent |

Runs 3–4 flake anatomy (test-side; none masked; recorded in `108beae`):
run 3 — the scrape-all gate accepted gb's flip while segacd's flags were
still flipping mid-batch, so the very next game POST raced into the
driver's serialized slot and took a deterministic 409; fix gates on batch
completion via in-flight-only markers. Run 4 lesson — bare "scraping"
matches the always-present page heading ("Metadata & scraping"), so the
marker anchors on `>scraping`, which only the running pill/button emit.

### Phase 5 adversarial review — reconciliation (2026-08-22)

5 findings, **4 fixed in code** (`0722aa7` ADV-P5-01, `82b947b` ADV-P5-02,
`4f76cb6` ADV-P5-03, `2fbe635`+D-P5b ADV-P5-04, `c9241fc` ADV-P5-05),
**1 partial: two sub-steps deliberately deferred to P6 with a documented
decision + runtime warning** (ADV-P5-04 / D-P5b). None rejected. Piece
stays in `review` until the blind critic.

| Finding | Disposition | What changed |
|---|---|---|
| ADV-P5-01 HIGH — cache dirs keyed by SkyHandle; script keys them by catalogue KEY (only `-p` gets the handle) → the 8 diverging systems miss their live europa caches (quota burn) and 3ds/new3ds collide on shared handle "3ds" | **fixed** (`0722aa7`) | scrape.go keys every `-d` path and the config ini on sys.Key (`-p` keeps SkyHandle); scanner.go countCacheGames + CacheDirFor keyed on sys.Key; catalogue.SkyPlatform doc no longer claims it keys caches; pinned argv expectation corrected + new TestCacheDirForKeysOnCatalogueKey pins the mapping and 3ds/new3ds collision-freedom |
| ADV-P5-02 HIGH — runPass folds child-output tails into errors/logs; a failing Skyscraper echoes its argv (Qt network errors embed URLs carrying ssid/sspassword) → credential leak into the journal today | **fixed** (`82b947b`) | per-run `secrets` redactor (SS creds + TGDB key as read); applied at THE choke point where tails enter errors/logs — every known value becomes `[redacted]`. TestScrapeSecretsNeverLogged grows the failing-echo phase (stub echoes its own argv incl. markers to stderr, exits 1): markers absent from logs, `[redacted]` + both pass-failure lines present so the check can't pass vacuously. Mutation-proven RED: removing sec.apply trips "SCREENSCRAPER CREDS LEAKED" |
| ADV-P5-03 MED — igir Runner and scrape Driver serialize only themselves; verify + scrape could overlap on the 2-core box | **fixed** (`4f76cb6`) | new internal/pipeline.Mutex (TryLock semantics), constructed once in main.go, handed to both runners; igir.Verify and scrape.Driver.start claim it first, failures map to each runner's existing ErrBusy sentinel so HTTP surfacing is unchanged (409 / swallow-in-goroutine). Unit tests: try-lock contract, each blocking direction, genuine mutual exclusion over one shared lock, no-run-row-on-reject, release-leak check; green under -race |
| ADV-P5-04 MED — driver omits four script post-steps without documentation | **fixed now ×2, deferred ×2 (D-P5b)** (`2fbe635`) | NOW: absolute→relative rewrite ("file:"/"assets.<key>:" values lose "<ROM_ROOT>/<sys>/" after compose — kiosks mount at /mnt/europa-cartridges) + whitespace-only-line deletion (Pegasus rejects following indented continuations; truly-empty survive). DEFERRED to P6 (which owns generation): seed_launchable_metadata + split_pending — recorded as D-P5b below, plus a driver warning when post-compose metadata is empty/lacks "launch: " ("collection unlaunchable until P6 seeding lands"). Tests: absolute-path fixture pins exact rewritten bytes; unlaunchable-warning matrix |
| ADV-P5-05 LOW — romSuffixes hardcodes 11 extensions; real systems carry 30+ | **fixed** (`c9241fc`) | romSuffixSet(row) builds the allowed set from the row's persisted Extensions JSON unioned with zip/bin; hardcoded list demoted to fallback for missing/unparseable rows (never widens to "any file"). TestROMSuffixSet: case-insensitive row-derived set, a .rpx tree counting under its row but not the fallback, malformed JSON → fallback |

### Phase 5 post-review verification (fresh, on the reconciled tree)

| Command | Result | Notes |
|---|---|---|
| `go build ./... && go vet ./... && go test -count=1 ./...` (in `pkgs/arcade-webapp`) | **pass** (2026-08-22) | 10 packages (pipeline joins): scrape suite grows cache-key pin, failing-echo secret phase (+mutation RED proof), mutual-exclusion trio, post-compose byte-exact rewrite + warning matrix, suffix-set semantics; scanner suite grows TestCacheDirForKeysOnCatalogueKey; igir suite grows TestPipelineMutexBlocksVerify; pipeline package has its own try-lock test. New tests also run green under -race |
| `make test-arcade-webapp` | **pass** (2026-08-22) | full VM smoke rebuilt the webapp from the reconciled tree (stdlib-only additions — no vendorHash change) and PASSED end-to-end incl. the P5 block (per-system scrape → nes desc/cover 0→100 via the stub, CSRF matrix, run history, windowed re-scrape) |
| `make check` | **pass** (2026-08-22) | 29 flake evals green, exit 0 |
| `make fmt` then `make fmt-check` | **pass** (2026-08-22) | fmt rewrote nothing; gofmt -l clean across pkgs/arcade-webapp |

### Phase 6 (P6 — launcher DB generator)

Builder loop 1 across six commits: `2c6c70f` strict self-validation parser
(internal/pegasus) → `ea841ac` carry-ins (enrichment columns v6, scanner
sha1 persistence, detail-page sha1 row) → `a3b20c7` the generator
(seed_launchable_metadata + split_pending semantics per D-P5b, atomic
write contract, golden/byte-stability/atomicity/pending tests) →
`91b3dc6` web wiring (POST /generate, Regenerate section + generation
log, post-verify trigger) → `61e2ec0` the igir launcher-DB-artifact
classification (root-caused regression, below) → `6ff8479` smoke-side
defects. VM runs: 1 FAIL (verify-all), 1 FAIL (same, retry-hardened),
1 FAIL (409), 1 FAIL (verdict grep), 1 FAIL (missing rescan trigger),
then runs 6+7 = two consecutive clean PASSes.

| Command | Result | Notes |
|---|---|---|
| `go test -count=1 ./...` (in `pkgs/arcade-webapp`) | **pass** (2026-08-23) | 13 packages green incl. new `internal/generate` (golden bytes w/ enrichment+assets+pending split+hidden exclusion, emulator-launch mapping, byte stability, completeness-sniff units .chd/.zip/optimistic, atomic-rename keeps old file on aborted generation, dry-run writes nothing, relative-path-only, unlaunchable refusal, newline sanitization, missing-dir failure) and `internal/pegasus` (valid/invalid fixtures: dup file targets, missing launch, newline-in-value, misplaced collection properties); web suite grows generate endpoint (CSRF 403 / 503 unconfigured / 200 sync / busy 409 via held slot / run recorded / fragment renders button+log rows / detail humanized never raw JSON / post-verify trigger matrix); igir suite grows TestParseReportLauncherDBArtifacts; store suite grows TestMigrateV6DatabaseStepsToV7 |
| `nix build .#arcade-webapp` | **pass** (2026-08-23) | no vendorHash change (all P6 edits stdlib-only — D-P1e rule held); binary present at result/bin/arcade-webapp |
| `make test-arcade-webapp` | **pass** (2026-08-23, runs 6+7 consecutive) | full smoke incl. the new P6 block: Launcher-database section + Regenerate affordance render; CSRF 403 bare POST; slot-free wait then 200 synchronous generate; served nes metadata carries `collection: Nintendo Entertainment System`, `launch: jupiter-retroarch -L fceumm "{file.path}"`, explicit game/file entries, zero absolute paths (`/var/lib/` grep); regeneration byte-stable (sha256 equal across two runs); kind=generate run recorded with "validated" detail cell; hidden exclusion BOTH directions (games.hidden seeded/cleared via sqlite3 CLI — curation UI is P7); pending split live: zeroed 1 MiB .chd scans as segacd's 2nd game, lands AFTER the marker inside `collection: Sega Mega CD & Sega CD (Pending)` / `shortname: segacd-pending` with NO second launch line in the file while the complete cue stays playable before it |
| `make fixture-arcade` | **pass** (2026-08-23) | igir gate still green: nes/snes/gb FOUND, **0 unmatched** |
| `make fmt` then `make fmt-check` | **pass** (2026-08-23) | clean, no diff; gofmt -l clean |
| `make check` | **pass** (2026-08-23) | every host evals incl. arcade-webapp-vm with the extended smoke |

**Bring-up failure log (each root-caused, none masked):**

1. **Runs 1–2 — verify-all amber everywhere:** after the first successful
   verify triggered a generation, EVERY subsequent system flipped to
   'extra'. Local probe against the pinned igir 5.3.0 proved it
   inventories ANY unknown file in both scanned dirs as output-side
   UNUSED — metadata.pegasus.txt and media/** included (it recurses;
   there is NO output-side exclude option). The provenance ingest was
   mapping those to Extra (amber). Fix `61e2ec0`: classify pipeline-owned
   launcher-DB artifacts as their own benign counter at ingest (D-P6c),
   schema v7 column, honest pill/run-detail naming.
2. **Run 3 — POST /generate 409:** the P5 game re-scrape still held the
   shared pipeline slot when the smoke generated (its stub-log marker
   lands mid-batch). Fix: slot-free wait on in-flight-only fragment
   markers before the block (the busy 409 itself is correct behavior).
3. **Run 4 — validation-verdict grep blind:** `grep -A2 '<td>generate</td>'`
   cannot reach a detail cell that sits five template-lines down a run
   row. Test-side only; widened to -A6.
4. **Run 5 — rescan assertion without a rescan:** the pending step
   dropped the zeroed .chd but never triggered the scan it then polled
   for. Added the POST /rescan.

### Phase 6 adversarial review — reconciliation (2026-08-23)

5 findings: **4 fixed in code** (`2d62bdd` ADV-P6-01, `1a2f4b0`
ADV-P6-06, `92f4a50` ADV-P6-02, `545cee4` ADV-P6-03), **1 accepted as
informational-only with a decision-log row** (ADV-P6-05 / D-P6e — no
generator change by instruction). None rejected. Piece stays in
`review` until the blind critic.

| Finding | Disposition | What changed |
|---|---|---|
| ADV-P6-01 MED (gating) — ReplaceSystemGames pruned with `last_seen_at < ?` against RFC3339 SECOND-truncated strings; a cross-second subset replace deleted games seen 1s earlier → TestGenerateGolden/TestGenerateByteStable ENOENT + TestDryRunWritesNothing panic flakes (~15% of -race runs) | **fixed** (`2d62bdd`) | store-level `gameStamp`: first/last_seen_at now persist as RFC3339 UTC with a **fixed 9-digit fraction**, so lexicographic order is chronological. Format choice documented on gameStamp: RFC3339Nano REJECTED (trailing-zero stripping misorders prefix fractions — `.5Z` sorts after `.52Z`, same bug class one level down); unix-milli REJECTED (TEXT column: legacy `2026-…` strings sort above any `17…` integer, pre-upgrade rows would never prune until rewritten). Migration compat: old-format rows in EARLIER seconds still sort below new stamps (no early deletion possible); an old-format row in the upgrade-boundary second only survives one extra prune cycle until its next upsert rewrites it — no backfill. Test hygiene independent of the fix: seedNES seeds in ONE batch. RED→GREEN proven: both new store tests (`TestReplaceSystemGamesPrunesAcrossSubSecondBoundary`, `TestReplaceSystemGamesLegacyStampRowsCompareSanely`) FAIL against HEAD's store.go and PASS after |
| ADV-P6-02 MED — kill -9 between CreateTemp and Rename strands `.metadata.pegasus.txt.<n>.tmp` in the SERVED tree forever; next igir verify counts it Extra → amber | **fixed** (`92f4a50`) | two layers: (1) every successful real Generate run sweeps dot-prefixed `*.tmp` siblings matching the temp pattern in each generated dir BEFORE recording the run row — temps now embed `os.Getpid()` at CreateTemp and own-pid temps are never swept (generations are already serialized within this process by the pipeline mutex; noted in-code), and nothing newer than process start is swept (overlapping restarts share the trees); dry runs NEVER sweep (P7 diff-preview purity); (2) `launcherDBArtifact` classifies tmp-shaped siblings of metadata.pegasus.txt at the system-dir root (pid-stamped + legacy shapes) as artifacts — defense in depth so pre-existing residue reads benign even before any sweep. Tests: forced-residue sweep (stale removed, fresh foreign-process + own-pid kept, generated file undisturbed), dry-run-never-sweeps, classifier matrix |
| ADV-P6-03 LOW — post-verify regeneration that found the pipeline slot busy vanished without a trace | **fixed** (`545cee4`) | explicit kind=generate run row, status `skipped`, detail "post-verify regeneration skipped (pipeline busy)" — visible in the generation history (runPill renders its own grey pill); PLUS the trivially-addable single deferred retry via `time.AfterFunc(30s)`. A retry that finds the slot busy again remains the accepted D-P6d residual. Test pins marker row + legible detail + exactly one deferred ok run after the slot frees |
| ADV-P6-06 LOW — Generator.State.LastOKAt declared+snapshotted but never assigned | **fixed — wired** (`1a2f4b0`) | smaller honest change vs deletion (State mirrors the igir/scrape/scanner runners' seam): lastOKAt stamped under the generator mutex on ok runs; the never-exported snapshot() becomes the exported State() accessor; previously unlocked lastErr writes moved under that lock; LastError now also names per-system build failures ("N system(s) failed generation") instead of only validation refusals. Test pins zero→ok→failure transitions (failed run keeps the last GOOD stamp) |
| ADV-P6-05 LOW — quote byte-shapes coexist (bare-quote vs backslash-escaped) between Skyscraper compose and our generator | **accepted, informational only** (D-P6e, this commit) | NO generator change by instruction: both shapes tokenize identically per CommandTokenizer; reconciled EMPIRICALLY at the AC-8c launch probe before europa cutover — see D-P6e |

### Phase 6 post-review verification (fresh, on the reconciled tree)

| Command | Result | Notes |
|---|---|---|
| `go build ./... && go vet ./...` (in `pkgs/arcade-webapp`) | **pass** (2026-08-23) | clean; gofmt -l clean across internal/ + cmd/ |
| `go test -count=5 -race ./internal/generate/ ./internal/store/` | **pass** (2026-08-23) | the ADV-P6-01 stability gate, ×5 under -race inside the full-suite run below (store 377s, generate 102s); the ~15% flake class did not reproduce once across 5 iterations of either package (previously reproduced by the adversary) |
| `go test -count=5 -race -timeout 30m ./...` | **pass** (2026-08-23) | ALL packages ok: aria2 11.9s · catalogue 1.1s · dats 27.4s · fixture 48.0s · generate 102.0s · igir 103.2s · pegasus 1.3s · pipeline 1.1s · scanner 115.1s · scrape 79.3s · store 377.7s · web 598.2s. Honest caveat: WITHOUT an explicit `-timeout`, the bare gate command dies on go's DEFAULT 10-minute PER-PACKAGE cap in internal/web (~650s needed at count=5 -race — linear scaling from 130s at count=1; every individual test passes; a budget property of the suite at this count, not a regression or a hang — recorded here so the gate is reproducible) |
| `make test-arcade-webapp` | **pass** (2026-08-23) | full VM smoke incl. the P6 block end-to-end: launcher-database section renders, generated nes metadata carries the catalogue launch line + zero absolute paths, regeneration sha256-stable, kind=generate run recorded + strict-parser validated, hidden exclusion BOTH directions, pending split live (zeroed .chd listed-not-launchable, cue playable) |
| `make check` | **pass** (2026-08-23) | all 29 flake evals green incl. arcade-webapp-vm; TWO evaluator OOM kills first (concurrent opencode sessions saturating RAM+swap — environmental, same class as P3's transient evaluator segfault), clean on re-run |
| `make fmt` then `make fmt-check` | **pass** (2026-08-23) | fmt rewrote nothing (no tracked-file diff); fmt-check silent |

### Phase 7 (P7 — curation)

Builder loop 1 across seven commits: `c03cebb` schema v8 collections +
bulk-unhide store surface → `48e1339` pegasus multi-collection
validation → `190b003` generator collection emission → `5537646`
enrichment ingest (the P6 critic carry-in) → `e68ddb6` web layer
(toggles, bulk action, collections UI, async regeneration) → `fec4765`
VM smoke extension → `3642a51` smoke assertion fix (BRE trap). VM runs:
2 FAILs (both smoke-side assertion defects, root-caused below), then
runs 3+4+5 = three consecutive clean PASSes.

| Command | Result | Notes |
|---|---|---|
| `go build ./... && go vet ./... && go test -count=1 ./...` (in `pkgs/arcade-webapp`) | **pass** (2026-08-23, fresh on the final tree) | 12 packages green incl. new suites: store `TestMigrateV7DatabaseStepsToV8` / `TestCollectionsCRUD` (shortname derivation + collision probing, stable-shortname rename, identity-checked idempotent membership, cascade delete) / `TestSetSystemHiddenAll`; pegasus cross-collection dupe allowance + duplicate-shortname rejection + 3-block order stability (RED proven against the previous whole-file rule); generate `TestGenerateCustomCollectionCrossSystem` (byte-exact goldens in BOTH member systems' files, launch line inherited per system, hidden members excluded), pending-member exclusion, shortname-sorted byte-stability; scanner `TestApplyCacheEnrichmentIngestsText` (verbatim ingest, undescribed games stay empty, later id-less pass never wipes); web hide-toggle / unhide-all / hidden filter / collections CRUD UI / collection-edit-triggers-regeneration suites |
| `go test -count=5 -race ./internal/generate/ ./internal/pegasus/ ./internal/store/` | **pass** (2026-08-23) | the ADV-P6-01 stability gate extended to cover the collection-emission code path — byte-stability holds ×5 under -race with custom blocks present |
| `go test -count=1 -race ./internal/web/ ./internal/scrape/ ./internal/scanner/` | **pass** (2026-08-23) | the new async-regeneration goroutines race-clean against the store and templates |
| `nix build .#arcade-webapp` | **pass** (2026-08-23) | no vendorHash change (all P7 edits stdlib-only within existing packages — D-P1e rule held); binary smoke: starts, logs secret-presence paths |
| `make test-arcade-webapp` | **pass** (2026-08-23, runs 3+4+5 consecutive) | full smoke incl. the new P7 block, all endpoint-driven (no sqlite seeding): enrichment e2e — after the stubbed scrape the served nes metadata carries exactly 5 `description:` lines incl. Starlit Vault verbatim; POST hide → button flips to Show + game excluded from generation → toggle back restores; CSRF 403 on every new mutating route; 'Kitchen quick-play' collection spanning nes+snes lands its block in BOTH generated files (launch line inherited per system so entries boot, member repeated under the block header, awk line-order checks, counts rendered in the kind=generate run detail); hiding a member removes it from EVERY surface; bulk show-all-hidden restores both |
| `make fixture-arcade` | **pass** (2026-08-23) | igir gate still green: nes/snes/gb FOUND, **0 unmatched** |
| `make fmt` then `make fmt-check` | **pass** (2026-08-23) | fmt rewrote nothing beyond intended files; fmt-check silent |
| `make check` | **pass** (2026-08-23) | all 29 flake evals green incl. arcade-webapp-vm with the extended smoke |

**Bring-up failure log (each root-caused, none masked):**

1. **Run 1 — zero description lines in the served file:** never
   reproduced again (runs 2–5 all carry them; local end-to-end repro of
   stub→driver→store→generator emits them deterministically). Recorded
   as an unresolved single occurrence superseded by four subsequent
   green observations; the smoke now asserts the exact count (5) so any
   recurrence fails loudly with data instead of silently.
2. **Run 2 — verbatim grep missed an existing line:** the assertion used
   `\(USA\)` — a BRE capture GROUP, which matches "USA" without the
   literal parentheses the region tag carries. Test-side only; fixed
   with `grep -qxF` (fixed string). The pipeline itself was correct.

### Phase 7 adversarial review — reconciliation (2026-08-23)

5 findings + 1 accepted-as-recorded: **4 fixed in code** (`77ea27d`
ADV-P7-01(+P7-05), `ce1a54d` ADV-P7-02, `64a01ec` ADV-P7-03(+P7-01b),
`c1de6a8` ADV-P7-04), **1 accepted as recorded** (ADV-P7-06). None
rejected.

| Finding | Disposition | What changed |
|---|---|---|
| ADV-P7-01 HIGH — collectionShortname derives from operator names unchecked: a collection named "NES" derived shortname `nes`, colliding with the catalogue system's main-collection shortname → generation REFUSED that system's file forever (strict-parser duplicate-shortname error) while create/add answered success and the async-regen failure landed only in journal+run rows | **fixed** (`77ea27d`) | store probes the DERIVED shortname against the systems table (the catalogue copy the scanner upserts — no injected list, nothing to drift) at create AND rename time, returning a typed `ReservedShortnameError` naming both sides; no suffix probe can rescue `nes`, and rename is probed symmetrically (it keeps its stored shortname so it cannot break generation itself — the guard keeps one mental model and lets pre-fix rows self-heal by renaming away). Handlers answer 409 with the collision named in the re-rendered panel; both collections layouts opt 409 bodies into htmx's `responseHandling` (stock config never swaps 4xx) so the inline error is actually visible. Tests: store rejection matrix (main identity, case folding, `-pending` section, error text names both sides, no rows left behind, non-colliding lands, free-rename allowed), UI 409s for create+rename |
| ADV-P7-01(b) — surface failed async regenerations to the triggering UI | **fixed** (`64a01ec`) | the coordinator records the last failed regeneration (validation refusal or per-system failures); collections panel, collection editor, game-actions region (where the hide toggle lives) and the metadata Launcher-database section render a visible warning marker naming where the log is; cleared by the next fully-ok generation (automatic or manual — `/generate` keeps it truthful). TestRegenFailureMarkerSurfacesToPages proves marker-on-failure across all surfaces and cleared-on-recovery |
| ADV-P7-02 HIGH — regenerationPass snapshotted generateOptions() BEFORE claiming generator+pipeline locks → G1(pre-state read) → G2(post-state gen+release) → G1 claims the freed slot un-rejected and overwrites the served tree with stale bytes (lost update) | **fixed** (`ce1a54d`) | smallest correct design: options snapshot moved INSIDE the locked region via a provider callback — new `Generator.GenerateFresh(dryRun, provide)` claims, then invokes the provider under BOTH locks, then renders; the manual /generate button and every trigger path moved onto it (`GenerateOptions` stays for pre-built-options callers/tests). Tests: TestRegenerationReadsOptionsUnderTheSlot reproduces the interleaving deterministically (the provider IS the stall hook — blocked mid-pass while a collection+membership land in the store; the generated file must carry them), TestFreshProviderOnlyRunsUnderLock pins that a held slot refuses WITHOUT invoking the provider |
| ADV-P7-03 MED — every mutation spawned its own regenerateLauncherDBAsync goroutine; busy hits each wrote a run row mislabeled "post-verify regeneration skipped" (wrong provenance for curation) plus a 30s AfterFunc each — N toggles during a verify flood history and hog the slot afterward | **fixed** (`64a01ec`) | dirty-flag + single worker goroutine: mutations call requestRegeneration(origin) (cheap, non-blocking); the flag is CLAIMED before each pass and a quiet-window gate holds the pass until the burst stops arriving (the naive claim-and-run chained 17 generations for 50 toggles — measured, then gated), so N rapid toggles cost 1–2 generations. Busy episodes write ONE coalesced row labeled accurately ("regeneration deferred — pipeline busy") with sorted provenance labels; post-verify keeps "post-verify promotion" distinct from curation's "curation edit"; the worker retries until the slot frees (no AfterFunc). Post-verify trigger migrated onto the same mechanism. Tests: TestRegenBurstCoalescing (50 toggles → 1–2 generations, zero skip rows, final state served), TestRegenDeferralCoalescedPerEpisode (one accurately-labeled row naming BOTH origins per episode, then exactly one deferred pass), TestPostVerifyGenerationBusyRecordsSkipAndRetries updated to the new contract |
| ADV-P7-04 LOW — unbounded description ingest in ApplyCacheEnrichment | **fixed** (`c1de6a8`) | rune-safe truncation at 4000 chars (generous vs real blurbs of a few hundred), logged ONCE per run naming system+count rather than per-game spam; normal-size text stays byte-verbatim (honesty contract). Test pins exact stored length, tail-gone, verbatim passthrough |
| ADV-P7-05 LOW — missing game→membership cascade store test | **fixed** (`77ea27d`) | TestGameDeleteCascadesCollectionMembership covers BOTH deletion paths: the scan-time prune (vanished file set removes exactly its system's memberships) and a direct games-row delete (FK ON DELETE CASCADE) |
| ADV-P7-06 — recorded by the reviewer with disposition accepted | **accepted as recorded** (no change) | stands as documented in the review record |

### Phase 7 post-reconciliation verification (fresh, on the reconciled tree)

| Command | Result | Notes |
|---|---|---|
| `go build ./... && go vet ./...` (in `pkgs/arcade-webapp`) | **pass** (2026-08-23) | clean |
| `go test -count=1 -race -timeout 25m ./...` | **pass** (2026-08-23) | ALL 12 packages ok incl. the new suites (web 66.8s, store 34.4s under -race); explicit timeout because the bare gate dies on go's 10-minute default cap in internal/web (recorded since the P6 reconciliation — same budget property, not a regression) |
| `make test-arcade-webapp` | **pass** (2026-08-23) | full VM smoke end-to-end on the reconciled tree — hide/show toggles, cross-system collection blocks, pending split, enrichment e2e all still green through the NEW single-worker trigger path (the smoke's gen_now retry loop models the coordinator honestly deferring while the slot is held) |
| `make check` | **pass** (2026-08-23) | all flake evals green incl. arcade-webapp-vm |
| `make fmt` then `make fmt-check` | **pass** (2026-08-23) | fmt rewrote nothing (no tracked-file diff); fmt-check silent |

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
| D-P2a — VM download fixture: webseed torrent, not a bare addUri | the plan's "download a small local file via http URL" is implemented as a self-authored mktorrent torrent (private, no trackers/DHT) whose single webseed IS the in-VM static server (darkhttpd) — the REAL acquire action is exercised end-to-end instead of a test-only URL-submit path. Range support is load-bearing: pause/resume stalls forever against python's `http.server` (ignores Range); darkhttpd answers it (verified locally, PoC: pause→paused, unpause→complete in 8 s, sha256 match). The daemon is throttled to 256 KiB/s over a 2 MiB payload so the pause window is deterministic | decided | `tests/hosts/arcade-webapp-vm.nix` P2 fixture block; local PoC transcript in the P2 work log |
| D-P2b — aria2 secret wiring: same existing sops key, no module-level declaration | `aria2SecretFile` keeps its null default + `config.sops.secrets.jupiter_aria2_rpc_secret.path` example (the SAME key `modules/services/aria2.nix` declares when the daemon is enabled — no new secret is created). The webapp module deliberately does NOT declare `sops.secrets.*` itself: a declaration under `mkIf enable` would force sops-nix into every consumer, breaking the deliberately sops-free VM test host (which passes an invented local test value instead — never a fleet secret). On europa the daemon's own declaration covers the key; a host enabling the webapp without the daemon gets a loud eval error pointing at the missing declaration. The webapp needs no new privileges: root + `ProtectSystem=strict` already reads `/run/secrets`, and the daemon — not the webapp — writes the download tree (aria2 creates `incoming/<sys>` itself, owned by the daemon user, which is exactly the ownership rom-acquire's `install -d` engineered) | decided | `modules/services/arcade-webapp.nix` option docs; CLAUDE.md secrets discipline |
| D-P2c — CSRF posture for mutating endpoints (closes ADV-P1-07) | every POST (incl. P1's `/rescan`) requires htmx's `X-HX-Request` header, else 403. Rationale: the service is LAN-only and cookie-less (no session to ride), so the htmx-documented custom-header check is the proportionate defense against cross-site form posts; plain curl callers just add the header (smoke does). Unit-tested for all five mutating routes; VM smoke asserts both the 202 (with header) and the 403 (without) | decided | `internal/web/downloads.go` `hxRequestOK`; `TestMutatingEndpointsRequireHTMXHeader`; VM smoke rescan section |
| D-P2d — VM serial-getty masked | the first P2 VM run died silently after "pause works" — no FAIL marker, machine powered off: the serial-getty's terminal-reset escape sequences on `/dev/ttyS0` interleaved with the smoke's output window (ADV-P1-04's race in a new costume). The vmVariant now disables `serial-getty@ttyS0` outright (the smoke is a systemd service; no shell needed), the resume step prints its POST status + periodic queue-state markers, and the driver honors `LOGFILE=` so failed runs keep their serial log | decided | `f0b29b2`; captured log of the silent death |
| D-P3a — igir sourcing: `pkgs.igir` from the fleet-pinned nixpkgs | igir 5.3.0 is IN the pinned nixpkgs (`nix eval nixpkgs#igir.version` = 5.3.0; same store path `37x4dna…-igir-5.3.0` inside the VM), i.e. the exact binary `make fixture-arcade` pins via `nix run --inputs-from . nixpkgs#igir` — so the module defaults `igirPackage = pkgs.igir` (overridable package option) and the VM runs the REAL igir, no store-path workaround, no new flake input (AC-9) | decided | `modules/services/arcade-webapp.nix` `igirPackage`; VM journal `verify runner wired (igir …-igir-5.3.0/…)`; fixture gate |
| D-P3b — DAT fetch host stubbed in the VM, darkhttpd doubled | the same in-VM darkhttpd that serves the P2 webseed also serves a stubbed Fresh1G1R tree at `http://127.0.0.1:8099/dats` (`datFetchBaseUrl` override) — tests never touch GitHub (house/A7 discipline). The stub serves a **re-dated copy** (2026-08-21→2026-08-22, sed) of the same committed nes DAT, so the refresh is *observable* in the UI (currency date moves) and darkhttpd's percent-decoding is load-bearing for the encoded McLean filenames (verified locally before wiring) | decided | `tests/hosts/arcade-webapp-vm.nix` stubRoot; smoke `DAT refresh via stub host worked (date 2026-08-22 rendered)` |
| D-P3c — igir CSV provenance semantics (input-side vs output-side) | igir scans BOTH `--input` and `--output`, so the same Status means different things per side — proven by running the real 5.3.0 over the fixture corpus with a pre-populated output tree. Adopted mapping: input-side UNUSED/DUPLICATE → **unmatched** (red — staged set deviates from 1G1R); output-side UNUSED → **extra** (amber — games-tree files the DAT doesn't claim; new schema v3 column); output-side DUPLICATE → **echo** (benign/informational — COPY keeps the staged input, so every re-verify after the first promotion emits these; counting them red would flip every green system red on its second verify); neither side → other (red, conservative). Alternative rejected: discounting the rows at parse time only — the served CSV would then literally show UNUSED rows against a green pill (a lying indicator) | decided | `internal/igir/runner.go` Report docs; `TestParseReportProvenance`; VM amber→green sequence |
| D-P3d — VM writable trees + hermetic disk | the games trees/DAT dir are materialized as WRITABLE copies by a oneshot ordered before the webapp unit (ReadWritePaths must exist at namespace-build time, D-P1f — and igir COPY-promotes into them; read-only store paths fail both), with the ROM corpus staged under `incoming/<sys>` (the .zip scanner shapes stay games-tree-only: staged zips would model junk-arrived-in-staging). The driver also takes a **fresh qcow2 per run** under a mktemp dir: the stock build-vm runner reuses `./<host>.qcow2` resolved against the invoking cwd, and surviving SQLite state once made fresh-tree assertions lie (nes already 'unmatched' before any verify) | decided | `tests/hosts/arcade-webapp-vm.nix` materialize service; `scripts/test-arcade-webapp.sh` hermetic-disk block |
| D-P3e — aria2 `.torrent` metadata companions excluded at the igir argv | the pinned aria2 1.37.0 writes an infohash-named `.torrent` into every download dir **even via `aria2.addTorrent`** (its docs claim magnet-only; disproven with a local daemon+RPC reproduction — so europa's real incoming tree will hold these after every acquire). They are daemon bookkeeping, not staged ROM content, and no DAT can ever claim a `.torrent` ROM — so `runIgir` adds the ONE deliberate deviation from cartridge-verify.sh's flag set: `--input-exclude <input>/**/*.torrent`. The report then literally carries zero unmatched rows for them (pill and CSV agree). Two load-bearing details, both proven against real igir 5.3.0: the glob must be `**` (a bare `*.torrent` does not cross separators) and must be **anchored to the absolute input dir** (igir expands exclude globs against the filesystem from the process cwd — a bare `**/*.torrent` under cwd=/ crawled the whole nix store for minutes as root, exactly the run-2/5 VM hang) | decided | `internal/igir/runner.go` runIgir; `TestArgvMatchesCartridgeVerifyScript`; local repro transcripts; VM run 6+ green with the companion deliberately left in staging |
| D-P5a — interrupted-unit disposition: KEEP, not revert | the session that produced `bb465d5` died leaving two files modified and uncommitted (`modules/services/arcade-webapp.nix`, `tests/hosts/arcade-webapp-vm.nix`). Fork analysis before keeping: the vm-test hunk cited "run-3"/"run-4" lessons ABSENT from committed history (`bb465d5` records only runs 1–2), i.e. post-push smoke iterations — follow-on hardening, not half-applied fragments of already-committed content. Marker claims verified against the template before trusting them: `hx-trigger="every 3s"` renders only under `{{if .State.Running}}`, and `>scraping` matches only the running pill/button while the heading's `&amp; scraping` never does. The module hunk was comment-only (11 lines losing a stray leading space — zero eval impact). Verdict: finish + commit as `108beae`, then re-verify fresh (all green above) | decided | `git diff` vs `git show bb465d5 --stat`; `templates/metadata.html` lines 27/34/37; verification log §Phase 5 |
| D-P5b — script post-steps: two ported NOW, seed_launchable_metadata + split_pending DEFERRED to P6 | cartridge-scrape.sh runs four post-steps after its pegasus compose; the P5 driver omitted all four (ADV-P5-04). Disposition: the **absolute→relative path rewrite** and the **whitespace-only-line deletion** are ported now (`2fbe635`) — both are pure correctness fixes on what Skyscraper already writes, cheap to unit-test byte-exactly, and load-bearing for kiosk launchability (absolute /tank/… paths make Pegasus on a /mnt/europa-cartridges mount drop every game + asset). **seed_launchable_metadata** (minimal launchable fallback when compose leaves an empty/launch-less file) and **split_pending** ((Pending) collection for incomplete downloads) are DEFERRED to P6, which OWNS metadata generation — porting them into the scrape driver now would mean P6 immediately rips them back out when it takes over generation. Until P6 lands, the driver warns loudly when post-compose metadata is empty or lacks "launch: " ("collection unlaunchable until P6 seeding lands") so the gap is observable in the journal rather than silently broken | decided | `internal/scrape/scrape.go` postCompose/rewriteRelPathLine + warning log; `TestPostComposeRewritesAbsolutePathsAndDropsWhitespace`; `TestPostComposeWarnsWhenUnlaunchable`; ADV-P5-04 row above |
| D-P6a — generator write surface: metadata.pegasus.txt only, roots reused, no new options | the generator writes EXACTLY each populated system dir's `metadata.pegasus.txt` plus dot-prefixed temp siblings in the same dir (temp+fsync+rename; kiosks never see a partial file). `media/` is REFERENCED relatively (assets.<key>: media/<base>/<file>) but never written by the webapp — Skyscraper's compose owns it, exactly as today. No new module options or env vars: the three bucket-root options P1 already declares ARE the served trees, and the generator shares them (main.go wires Generator over cfg's roots). Unlaunchable systems (no core AND no emulator mapped) refuse generation loudly instead of writing an unlaunchable collection | decided | `internal/generate/generate.go` writeAtomic/targetName; `modules/services/arcade-webapp.nix` comment; `TestMissingDirFailsLoudly`, `TestSkipsEmptyAndUnlaunchable`, `TestAtomicRenameKeepsOldFileOnAbortedGeneration` |
| D-P6b — custom collections: seam declared now, loud rejection until P7 | `generate.Options.CustomCollections` is the P7 curation seam (named member lists → first-class Pegasus collection blocks). Passing any before P7 returns an error rather than being silently ignored — a silent drop would make P7's diff preview lie about what the kiosk will see. `Generate(dryRun bool)` is exported for P7's before/after diff flow | decided | `internal/generate/generate.go` Options/GenerateOptions; generate_test.go coverage |
| D-P6c — igir inventories launcher-DB files; classify artifacts at ingest (schema v7) | root-caused in VM runs 1–2 with a local probe against pinned igir 5.3.0: igir emits output-side UNUSED for EVERY unknown file in the scanned trees — metadata.pegasus.txt and everything under media/ (recursion verified) — because it treats scanned dirs as ROM candidates regardless of extension. There is NO output-side exclude option (only --input-exclude; help verified), so the D-P3e argv-level fix is unavailable. Per D-P3c's own provenance principle (same raw status, different meaning by context), output-side UNUSED rows for `metadata.pegasus.txt` / `media/**` are classified as benign ARTIFACTS at ingest — counted in a new Report.Artifacts, persisted via verify_results.artifacts (schema v7), and NAMED in pill titles and run detail ("N launcher-DB artifact(s) ignored") so the operator sees why the served CSV carries the rows. Without this, every verify after every generation sits amber forever — on the VM and on europa alike. Input-side metadata files stay red junk (staging should never hold them) | decided | `61e2ec0`; probe transcript in P6 work log (`/tmp/opencode/igir-probe`, rep.csv showing UNUSED for both artifact paths); TestParseReportLauncherDBArtifacts; TestMigrateV6DatabaseStepsToV7 |
| D-P6d — triggered regeneration is best-effort; busy-window retries are operator semantics | the post-verify trigger runs best-effort in the verify goroutine (never fails the verify that caused it; skipped for failed/empty batches) and claims the shared pipeline slot like any heavy job. Consequence: an action POSTed inside the post-verify generation window is rejected ErrBusy and swallowed (P3's documented handler semantics) — acceptable for humans (click again) and made deterministic in the smoke via bounded retry loops that model exactly that. The manual Regenerate button surfaces 409 honestly instead of queueing (one-at-a-time is the R5 contract). ADV-P6-03 refinement (`545cee4`): a busy post-verify regeneration is no longer SILENT — an explicit skipped run row marks the history and one deferred 30s retry runs | decided | `91b3dc6`; VM smoke verify_until helper + run-3 root-cause note above |
| D-P6e — quote byte-shapes coexist between Skyscraper compose and our generator; reconcile empirically at the AC-8c launch probe, NOT by unifying early | bare-quote values and backslash-escaped-quote values coexist across launcher-DB sources: Skyscraper's compose output and our generator (renderSystem's `launch:` line uses literal `"` bytes) can carry different BYTE shapes for the same quoting intent. Both tokenize identically per Pegasus CommandTokenizer semantics, so there is NO behavioral difference today and no served-file churn is justified — changing the generator's quote shape now would rewrite every metadata file byte-wise for zero functional gain and invalidate the golden fixtures (ADV-P6-05: informational only, no code change). The reconciliation is EMPIRICAL and deferred to the AC-8c launch probe: prove on a real kiosk that both shapes launch identically BEFORE europa cutover; only a observed divergence justifies touching the generator then | decided (deferred evidence gate) | `internal/generate/generate.go` renderSystem header/launch line + golden fixtures; plan §AC-8c CommandTokenizer reference; ADV-P6-05 reconciliation row above |
| D-P7a — parser dupe semantics: whole-file file:-uniqueness relaxed to PER-COLLECTION; repeated shortnames within one file rejected | the P7 emission spec (member game blocks repeated under a custom-collection header in the SAME system file) is Pegasus's documented multi-membership idiom and requires the same `file:` target to appear under two collections in one file. The real hazard the P6 rule guarded — a ROM listed twice in ONE grid — is preserved as a per-collection invariant; cross-collection repeats within a file are allowed, and the same collection name recurring across FILES stays the documented cross-file merge (each Parse sees one file, nothing to enforce). A duplicate shortname within one file remains rejected (ambiguous merge target). The plan text ("cross-collection dupes allowed across FILES but rejected within one file") is ambiguous between these readings; both stable interpretations are pinned by tests | decided | `internal/pegasus/pegasus.go` Validate + `TestValidateAllowsCrossCollectionFileDupes` / `TestValidateRejectsDuplicateShortnameInOneFile`; generator goldens `TestGenerateCustomCollectionCrossSystem` |
| D-P7b — curation surface choices: bulk unhide on the VERIFY worklist; creation skips the regeneration trigger; v6 description column reused not re-added | three scope-letter ambiguities resolved deliberately: (1) "show all hidden on the verify/metadata pages" lands on the VERIFY worklist rows (verify & organize IS the organize home), rendered only when hidden>0 — the library keeps the ?hidden= filter for discovery; (2) creating an EMPTY collection does not fire the async regeneration (provably output-neutral — no members, no block) while every membership/identity edit does; (3) the scope's "new description TEXT column via migration" already existed since schema v6 (games.description, nullable) — it is REUSED with a new ingest path (ApplyCacheEnrichment) rather than duplicated; only the collections tables are genuinely new (v8) | decided | verify worklist template + `handleSystemUnhideAll`; `handleCollectionCreate`; store.go SchemaVersion comment; VM smoke enrichment assertions |

## Gauntlet scoreboard

**7 won / 1 remaining (P1–P7 won)**. Exit (AC-10) = every piece P1–P8 won with the final
named-gap=null or an accepted-residual note recorded in the piece table.
