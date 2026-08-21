# Arcade Webapp Gauntlet — Progress

The live heartbeat of the builder/critic loop driving
[the plan](arcade-webapp-gauntlet.md). Updated at every piece boundary and
every critic verdict. Screenshots (when they exist) land under
`arcade-webapp-gauntlet/` next to this file.

- **Phase:** 2 in progress — **P1 won** (blind critic, 1 loop, 0 rebuilds) ·
  **P2 won** (blind critic, 1 loop, 0 rebuilds) · **P3 built — in review**
- **Branch:** `arcade/webapp-gauntlet`
- **ADR:** [ADR-0002 — custom, not RomM](../adr/0002-arcade-webapp-custom-vs-romm.md)
  (D1 research-confirmed 2026-08-21; D2–D4 accepted)
- **Last update:** 2026-08-22 04:35 AEST

## Piece table

| Piece | State | Builder loops | Last critic verdict | Critic's named gap | Evidence |
|---|---|---|---|---|---|
| P1 — Pipeline dashboard | **won** | 1 (0 rebuilds) | **ours** (blind, labels stripped; DOM A/B, data-scale asymmetry disclosed+discounted) | download stage has no surface (queue depth/active/errored/throughput) — folds into P2; meters lack `role="progressbar"`/`aria-valuenow`, polling regions lack `aria-live` (carry to P2) | `p1-ours-desktop.png`, `p1-ours-mobile.png`, `p1-bar-desktop.png`; critic: "B answers the 5-second question in one strip… A contains zero pipeline vocabulary — verify 0, torrent 0, scan 0, coverage 0" |
| P2 — Download control | **won** | 1 (0 rebuilds) + adversarial reconciliation | **ours** (blind, labels stripped; A=AriaNg's literal list-view template extracted from its shipped JS bundle, B=ours rendering a live aria2d queue: 2 active 64 MiB, 1 paused, 3 completed) | acquire column is a dead end when the torrent is missing — no stage/paste/trigger control on-page (carried to P3) | `p2-ours-downloads.html`, `p2-bar-ariang-list-template.html`, `p2-ours-{desktop,mobile}.png`; critic: "B understands the job is a collection pipeline, not a file list… A manages the daemon, not the collection"; implementation commits `f883582`/`ad361c2`/`b8f8315`/`f0b29b2`, review fixes `4be90e9`/`dfa680b` |
| P3 — Verify & organize | **review** | 1 (real-igir bring-up: 3 root-caused VM failures, 0 masked) + adversarial review pending | — (critic run pending) | — | commits `ca09507` (Go half) + `b1809bc`/`ce84fde` (real-igir refinements + wiring); VM smoke 27 steps green ×2 consecutive incl. REAL igir amber-extra → green zero-unmatched on a fresh promotion (log excerpt in the Phase 3 verification section) |
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

## Gauntlet scoreboard

**2 won / 6 remaining** (P1, P2). Exit (AC-10) = every piece P1–P8 won with the final
named-gap=null or an accepted-residual note recorded in the piece table.
