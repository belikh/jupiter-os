# SPEC — jupiterOS Arcade Remediation Programme

**Status:** active (W0 landed 2026-08-29)
**Authority:** `research/notes/final_report_jupiteros-arcade-remediation-e0e261.md`
(the diagnosis §1–4, benchmarks §5, plan §6, handoff §7). This SPEC is the
working transcription of that report's plan §6 and handoff §7 into the
repo's artefact grammar (SPEC → PLAN → TASKS per workstream). Where this
file and the report disagree, the report wins; where both disagree with
the code, the code wins and the discrepancy becomes a finding.

---

## 1. The constitution

These rules bind every workstream, every agent and every human. They are
the plan's §7.A made local and mechanical.

1. **Repo docs are hypotheses, not sources.** ADRs, post-mortems, the
   stack guide, and this SPEC's own claims about live state are to be
   re-verified against code and primary sources before anything builds on
   them. Two load-bearing internal claims were proven wrong in August
   2026 alone (the `summary:` post-mortem gloss, overturned by the
   Pegasus parser source; and the stack guide's SQLite ban / "europa is
   storage only", contradicted by the shipped SQLite webapp on europa —
   see §5 escalations).
2. **Every adoption pairs with its dated decommission trigger at adoption
   time.** Adding a component without committing its retirement path is
   generation four. Rows live in
   `docs/plans/arcade-remediation-ledger.tsv` (kinds: `adoption`,
   `deferral`, `decommission`), enforced by CI.
3. **Deferrals are ledger rows with dates and CI reminders, never
   prose.** A prose deferral produced the unwitnessed europa cutover.
   `scripts/ledger-check.sh` fails CI when a row's trigger date arrives
   with the row still open; re-dating requires a written reason in the
   row's note; deleting a due row to go green is unconstitutional.
   A row's trigger date is a commitment to *revisit*, not a deadline to
   ship.
4. **CI gates are blocking and identical for agents and humans.** Never
   weaken, skip or delete a failing test. A red gate is a finding, not an
   obstacle. **A skipped check is a failed check.** Gates must be listed
   as required status checks (operator action — see §6, W0 residue).
5. **Every task closes on an evidence record:** a command, a result, and
   an artefact path. "Done" without a run is a failure by definition —
   the single lesson the August record teaches.
6. **Deployment to europa or any kiosk is denied to agents.** Deny-first
   rules in `.opencode/opencode.json` (nixos-rebuild switch/test/boot,
   ssh root@\*, force-pushes). Host switches and live observations run
   through the operator-assisted path and must produce the before/after
   evidence artefacts the plan specifies (Lane E). Live deployment stays
   on the CI dispatch path.
7. **Findings over workarounds.** Evidence contradicting the plan's
   assumptions — above all europa's *inferred* unit state (never
   observed; the stale comment at `hosts/europa/configuration.nix` still
   misdescribes the host either way) and the *unmeasured* household
   gallery preference — is flagged, not routed around.

**Escalation rule:** where the stack guide and ADR-0002 contradict (SQLite,
europa's host role, the "~5k lines" burden), the implementer escalates for
adjudication and does not pick silently. See §5.

---

## 2. Workstream sequence (report §7.B)

Execute in order. **No new feature work opens until the three Phase-0
evidence records exist** (europa unit state, one recorded Tier-2 kiosk
launch, dated deletion triggers — W2). Every workstream ships its own
SPEC/PLAN/TASKS artefacts and closes only on evidence records.

| WS | Scope | Status |
|---|---|---|
| **W0** | Constitution and gate stand-up: deny rules, L1 lane, L2 harness conversion with fail-loud KVM probe, guardrail configuration | **landed 2026-08-29** (this commit; evidence §6) |
| **W1** | Phase-0 Lane T exposure triage: sanoid on the state dataset, delete disarmament (`filter-to-1g1r.sh`), kiosk sudoers locking, aria2 RPC rebind to loopback | **landed 2026-08-29** (module/config changes; takes effect at each host's next deploy — evidence §7) |
| **W2** | Lane E evidence-closure — **operator-assisted by design**: europa retro-audit (unit state + activated-generation diff around the 2026-08-25 switch, re-bless the stale comment), one recorded Tier-2 kiosk launch (AC-8c), dated machine-checked deletion triggers for `scripts/deprecated/` | blocked on operator |
| **W3** | Lane G completion: L2 harness conversion (done in W0 where cheap), L3 chromium-in-VM Playwright lane (fails on any 4xx and any duplicate panel id), nspawn contingency documented | **landed 2026-08-29** (evidence §8; negative-proven against the 403 class) |
| **W4** | Phase-1 standards: security/service hygiene (§6.F), DAT supply chain (§6.G), kiosk operability spec (§6.H), pipeline correctness + consolidation (§6.I) | queued |
| **W5** | The G0 gallery trial: pre-registered arms (scan kill/resume, 8 GB-class checksum pass, on-host contention, byte-equivalent Pegasus output, the one-evening household demo-session); written verdict either way | queued |
| **W6** | The chosen gallery branch, inside decommission grammar (cession to unmodified `services.romm` + ~300–500-line generator, or frozen-gallery branch with `internal/web` growth stopped) | gated on W5 |
| **W7** | Boundary-conditioned refinements, each behind its measurement: SSE only once the browser lane can assert event-name contracts; recycle cadence against measured scan contention; observability depth on measured need; root-free overlay once the sudoers lock proves insufficient | deferred by ledger |

Phase exits (report §6.K): Phase 0 exits when europa's unit state is
recorded evidence, one kiosk launch is a recorded artefact, deletion
triggers are CI-enforced, the public RPC ingress is loopback, state is
snapshotted, and L1–L3 gate every PR. Phase 1 exits when fail-closed auth
and the full hygiene set are live, the DAT lock and alarms have survived
one promotion cycle and the freeze alarm has fired on a simulated
asymmetry, the kiosk ladder has recovered an induced failure, and the
gallery verdict is written with its decommission date committed. Phase 2
exits when the last deprecated line is deleted on schedule and the fleet
answers "what did we verify against, and when?" in one query.

---

## 3. The gate matrix (report §6.E)

| Tier | Gate | Runs where | Status |
|---|---|---|---|
| L0 | nixfmt + `nix flake check --no-build` + **ledger gate** | every PR (`check` job) | live (ledger added by W0) |
| L1 | `go vet` + `go test -race` + igir fixture gate on `pkgs/arcade-webapp` | KVM-less hosted runner (`arcade-webapp-l1` job; `make check-arcade-webapp` locally) | **live (W0)** |
| L2 | the 1517-line harness as `checks.x86_64-linux.arcade-webapp-vm` (`testers.runNixOSTest`) | `arcade-webapp-l2-vm` job, udev unlock + fail-loud KVM probe | **live (W0)** |
| L3 | chromium-in-VM Playwright lane driving the real dashboard; fails on any 4xx and any duplicate panel id | same VM lane, in-tree Playwright packaging | **live (W3)** |
| L4 | synthetic europa-shaped fixtures (extension-less covers, real TSV profile) + on-host live-data timer | hosted + europa | with W4 |
| L5 | kiosk boot/session smoke: gamescope + Pegasus session, `READY=1` asserted inside 60 s | hosted | with W4 (kiosk spec) |

Binding conditions:
- **The fail-loud `/dev/kvm` probe is mandatory** on every VM lane. The
  documented silent failure is TCG fallback (10–12× slower) that
  misdiagnoses as flaky timeouts — the exact class that gets a gate
  deleted in week two.
- **Hosted KVM for public repos is generosity, not contract.** The
  nspawn/container degraded tier is a *named contingency lane*
  (W3 — design committed at
  `docs/plans/arcade-l3-nspawn-contingency.md`), not a hope.
- **Europa's private library never enters public CI.** Real *data shape*
  belongs there as a synthetic profile; real *data* is validated on-host
  (L4).
- **Forged-header curls are banned from evidence.** Every user-visible
  mutation must be proven through a client that sends only what a real
  browser sends.

Capacity ledger (report §6.A), binding on W4+: europa is 2 cores / 7.7 GB
serving NFS with one recorded OOM and one two-hour 87%-CPU boot. Nothing
new lands on europa before the caps exist; the RomM trial runs
watcher-disabled and off-peak; the nightly kiosk recycle is scheduled away
from the DAT scan window.

---

## 4. Acceptance criteria (report §6, per workstream)

Copied from the plan; the report remains authoritative for wording.

**W4a — security & service hygiene (§6.F).** An unauthenticated
non-loopback request gets 401 or the opt-out is logged as a page-worthy
event; SIGTERM drains in-flight requests in L2/L3; `kill -9` mid-verify
leaves no orphaned `running` row after restart. Scope: refuse-to-serve on
non-loopback listeners until auth or an explicit logged alarming opt-in;
full production-Go server set (timeouts, `MaxBytesReader`,
signal-driven graceful drain); stdlib `CrossOriginProtection`; htmx
defaults audited and pinned (`allowEval:false` where `hx-on` unused, CSP
layered); `MemoryMax`/`CPUQuota`, explicit start limits, version stamping
from git.

**W4b — DAT supply chain (§6.G).** Killing the upstream feed turns a page
red within 21 days; no ROM is ever evicted against a DAT older than the
lock without a human-approved diff. Scope: content-addressed `dat-lock.json`
(`source_commit` full SHA, `bytes_sha256`, `core_sha256`, `rom_count`,
`fetched_at`), commit-pinned raw URLs, promotion refused on hash mismatch,
one commit per accepted generation; append-only `dat_versions` ledger
replacing the `SetDATInfo` overwrite; liveness alarm on the asymmetry
itself (no-intro frozen >21 d while redump <14 d); churn audit as a log,
never a page; promotion gate as constants + procedure (auto-promote
additions-only; human approval beyond removals of max(5 titles, 0.5%));
identity re-keyed by hash not path; rename-before-parse reversed.

**W4c — kiosk operability spec (§6.H).** L5 smoke boots to `READY=1`
inside 60 s in VM; a killed (induced) compositor self-recovers within one
ladder step; no kiosk runs an interactive sudo helper. Scope: notify
wrapper asserting `READY=1` on menu-accepting-input; `WatchdogSec` armed;
recovery ladder with explicit numbers (watchdog → SIGABRT →
`Restart=always` → start limits → `OnFailure` reboot → boot-count guard to
the rescue console); nightly `RuntimeMaxSec`-style recycle off the scan
window; `jupiter-arcade.slice`; activation-time mount units replacing the
session's sudo path; explicit `providers.*.enabled` seed.

**W4d — pipeline correctness & consolidation (§6.I).** The three
convergence proofs green in CI (run-twice and kill-and-restart on verify,
scrape, generate); one source per flag set, demonstrable by grep. Scope:
startup sweep for orphaned `running` rows; cancellation path for running
batches; TOCTOU closed by re-checking `.aria2` control files before exec;
post-verify rescan outside the heavy-job lock; one igir flag source; bash
aria2 client twin retired; TSV↔Go equivalence test; `scripts/` under
shellcheck in L0; igir pin reviewed (5.3.0 vs the 5.4.0 line).

**W5 — the G0 gallery trial (§6.J).** A written verdict with the losing
surface's deletion or freeze date committed, before any gallery code
changes. Arms itemised from RomM's own tracker: kill a scan mid-run and
assert no phantom lock and clean resume (#4172/#4186/#4220); a compressed-
archive checksum pass sized for 8 GB against europa's 7.7 GB (#1262 may
fail informatively); contention measured on europa under load against
kiosk NFS reads; byte-equivalent Pegasus output against the existing
golden corpus; the one-evening household demo-session the original
decision never ran. Both branches are decommission events, not adoptions.

---

## 5. Open escalations and carried caveats

**ESCALATIONS (constitution rule: do not adjudicate silently).**

1. **SQLite.** `docs/stack-guide.md:55` ("avoided everywhere, including
   'just embedded'… New state goes to…" / line 132's reject-on-sight rule)
   vs ADR-0002 D3 (SQLite via `modernc.org/sqlite` as the deliberate
   store choice) and the shipped, merged, europa-deployed webapp. One of
   the two documents is wrong about a load-bearing rule. Needs
   adjudication: either the stack guide gains a scoped exception or the
   webapp's store is re-litigated. (W0 note: the remediation plan's §6.F
   work proceeds against the *code*; the doc conflict does not block
   hygiene work.)
2. **europa's host role.** Stack guide: "europa is NAS-only / storage
   only" vs ADR-0002 + `hosts/europa/configuration.nix` (arcade webapp,
   aria2, Skyscraper — a pipeline host). Same class as above; the
   capacity ledger (§3) prices europa as a pipeline host.
3. **ADR-0002's admitted burden.** "~5k lines of Go we maintain" vs the
   measured 26,759 (5.4×). Not a contradiction to adjudicate so much as
   the measured input to W5's verdict.

**CARRIED CAVEATS (report rule 6 — findings, not workarounds).**

1. **europa's live unit state is inferred, not observed.** Git history
   records a production boot of the webapp on 2026-08-25; nothing records
   what that switch retired; the comment at
   `hosts/europa/configuration.nix:510-529` still says the live host runs
   the old units "until the next switch". W2's retro-audit converts this
   to record — or upgrades the silent cutover to a live double-writer
   hazard and reorders Phase 1 first.
2. **The household gallery preference has never been measured.** No demo
   comparison was ever run. W5 exists to close this; no gallery work
   before its verdict.

---

## 6. W0 completion record

Every task closes with a command, a result, an artefact path. Latest
first; local run evidence verbatim in the PR body.

| Task | Command | Result | Artefact |
|---|---|---|---|
| SPEC + constitution | this file | written | `SPEC.md` |
| Deferral/decommission ledger | `./scripts/ledger-check.sh` | OK (9 lines, no due open rows) — negative path also proven (due row + malformed row both fail) | `docs/plans/arcade-remediation-ledger.tsv`, `scripts/ledger-check.sh` |
| Flake eval gate | `nix flake check --no-build` | pass (checks.x86_64-linux.arcade-webapp-vm evaluates to `vm-test-run-arcade-webapp-vm`) | `flake.nix` |
| Nix formatting | `nix fmt flake.nix tests/hosts/arcade-webapp-vm.nix` | applied, re-checked clean | — |
| L1 lane (vet) | `nix develop -c bash -c 'cd pkgs/arcade-webapp && go vet ./...'` | pass | `Makefile` (`check-arcade-webapp`), `.github/workflows/ci.yml` (`arcade-webapp-l1`) |
| L1 lane (race) | `… go test -race ./...` | pass (all packages, see report body) | same |
| L2 lane (VM test) | `nix build -L --no-link .#checks.x86_64-linux.arcade-webapp-vm` | **First run RED — the gate's first catch** (see below); after root-cause + selector fix, re-run GREEN: `ARCADE-WEBAPP-VM: PASS`, verdict file asserted in 143.99 s, test script finished in 144.56 s, output `/nix/store/1bgkhrxw…-vm-test-run-arcade-webapp-vm` | `flake.nix`, `tests/hosts/arcade-webapp-vm.nix`, `.github/workflows/ci.yml` (`arcade-webapp-l2-vm`) |
| Standalone VM path (regression guard) | `TIMEOUT_SECS=900 ./scripts/test-arcade-webapp.sh` | pass — `>> arcade-webapp-vm: in-VM smoke PASSED.` (serial-grep + self-poweroff behaviour unchanged by the L2 edits) | `tests/hosts/arcade-webapp-vm.nix` (poweroff default preserved) |
| Workflow lint | `actionlint .github/workflows/ci.yml` | clean for W0 additions; one pre-existing shellcheck nit (unused loop var, build-host step, untouched by W0) | — |
| Deny-first rules | `jq empty .opencode/opencode.json` | valid; 14 deny rules (nixos-rebuild switch/test/boot, switch-to-configuration, ssh root@\*, force-pushes incl. `--force-with-lease` and `+ref:` refspecs) | `.opencode/opencode.json` |

**The L2 gate's first catch (2026-08-29, recorded as a finding per
constitution rule 7).** The first runNixOSTest execution failed at the P7
curation block: `hide response did not re-render its button flipped to
Show`. Root cause, established from git: the smoke's selector grepped
`Show</button>`, but commit `5533d1e` (2026-08-28 08:43, the swap-contract
fix) rebuilt the `game-actions` region with the label span-wrapped for the
htmx indicator — and the VM harness had not been executed even once since
`680fe9a` (2026-08-23 23:05), because no CI lane ran it. The drifted
assertion sat in the tree for six days. The contract itself (POST hide →
200 → label flips to Show) was intact; the test's model of the markup was
stale — precisely the belief-based-gate failure class the remediation
exists to kill. Resolution: selector updated to the current contract
(`<span>Show</span>`) with the rationale recorded in the harness; the
flip is still fully asserted; re-run GREEN (above). Nothing was weakened,
skipped or deleted.

**W0 residue (operator actions, not agent-executable):**
1. Mark `check`, `arcade-webapp-l1`, `arcade-webapp-l2-vm` as **required
   status checks** in branch protection — the YAML alone does not block
   merges.
2. Restart opencode sessions so `.opencode/opencode.json` deny rules load
   (config is read at startup).
3. Confirm the repo's visibility class still receives hosted KVM; if
   `/dev/kvm` ever disappears, the L2 probe fails loud and the W3 nspawn
   contingency becomes the lane.

**Adoptions registered (constitution rule 2):** W0-A1 (L1 lane), W0-A2 (L2 lane),
W0-A3 (devShell go) — each with a dated gate-rot review row in
the ledger. Declined-with-reasons items are ledger rows W0-D1…W0-D5, not
prose.

---

## 7. W1 completion record — Phase 0 Lane T (exposure triage)

All changes are module/config changes: **they take effect at each host's
next deploy** (constitution rule 6 — agent deployment is denied). Operator
steps in the residue list below.

| Task | Change (file:line) | Command | Result | Artefact |
|---|---|---|---|---|
| T1 loopback rebind | `modules/services/aria2.nix:224` (`--rpc-listen-all=false`), `:326-331` (firewall no longer opens `rpcPort`) | `nix flake check --no-build` | pass (europa evals; see below) | `modules/services/aria2.nix` |
| T1 secret off argv | `modules/services/aria2.nix:211-230` (`LoadCredential` + runtime `--conf-path`, umask 077, fail-closed empty-secret check) | `nix eval …services.aria2.serviceConfig --json`; built + `shellcheck`'d the rendered ExecStart | `LoadCredential` → `/run/secrets/jupiter_aria2_rpc_secret`, `RuntimeDirectory=aria2`; rendered script has no `--rpc-secret` and binds loopback (full text in the PR body) | same |
| T1 tunnel route removal | `hosts/europa/configuration.nix` (rpc.jupiter.au ingress block replaced by the ariang note); ledger W1-X1 (done) | `nix eval …cloudflared.tunnels.<id>.ingress --json` | hostnames: ariang/cache/ha-mcp/headscale/nom/suno — **rpc.jupiter.au absent** | ledger row W1-X1 |
| T1 AriaNg keeps working | `modules/services/aria2.nix:302-312` (`locations."/jsonrpc"` proxy); `rpcWebPort` defaults to the vhost port; europa `rpcHost` → `10.1.1.2` | `nix eval …nginx.virtualHosts.ariang.locations --json` | redirect `302 …/http/10.1.1.2/8083/jsonrpc`; proxy `http://127.0.0.1:6800` + websockets; firewall eval: 6800 absent, 8083/6881 present | same |
| T2 sudoers pinning | `modules/desktop/exodos.nix:473-494` (`security.sudo.extraRules`: 3 extract + 1 c-drive pinned vectors; fixed merge-mount prefixes, literal `gamer:users`) | `nix eval .#nixosConfigurations.amalthea.config.security.sudo.extraRules --json` | four pinned command strings; the only other rules are the password-required root/wheel defaults — no argument-unlocked NOPASSWD entry remains | `modules/desktop/exodos.nix` |
| T2 helper validation | `modules/desktop/exodos.nix:136-309` (both helpers: arg-count, locked chown target, realpath-canonicalised prefix confinement, single-component target name, `.zip`/`.vhd` suffixes, zip-inside-parent invariant) | built both helpers from the amalthea closure; 13 hostile-vector fixture runs + 2 legit-shape runs (prefix substituted `/mnt/exo-games` → tmp, every other byte identical) | all hostile vectors exit 2 with the precise `die()` message; legit shapes pass validation and reach the privileged section (expected EPERM as the non-root test user) | `/tmp/opencode/w1` fixtures; scripts above |
| T3 sanoid on state | `modules/storage/sanoid.nix:69-100` (`tank/archive/retro/state` = important; `metadata/no-intro-dats` + `metadata/skyscraper-cache` = bulk; exclusions documented) | `nix eval .#nixosConfigurations.europa.config.services.sanoid.datasets --json` | all three datasets present with expected templates | `modules/storage/sanoid.nix` |
| T3 stale comment fixed | `modules/storage/zfs-nas.nix` (state dataset comment re-attributed to arcade-webapp; it still named the removed arcade-inventory unit) | `nix flake check --no-build` | pass | `modules/storage/zfs-nas.nix` |
| T4 `local` bug + dry-run gate | `scripts/filter-to-1g1r.sh:200` (`qcount=0` — the `local`-outside-function abort is gone); `:46-64` `--apply` opt-in + `-h`; roots env-overridable (dat-clean pattern) | `bash -n`, `shellcheck` (clean incl. the two built helpers + aria2 exec), fixture dry-run/apply runs | dry run: zero mutations (igir never invoked, trees byte-identical) and Step 3 completes — previously it aborted on the first system; `--apply`: report-driven move-back, gated hard-delete of strays, quarantine of unpromoted leftovers, igir invoked, rc=0 | `scripts/filter-to-1g1r.sh` |
| Ledger rows | `docs/plans/arcade-remediation-ledger.tsv` (W1-D1 deferral, W1-X1 decommission-done) | `./scripts/ledger-check.sh` | OK | the ledger |
| Full L0 lane | — | `nix run nixpkgs#nixfmt -- --check .` ; `nix flake check --no-build` ; `./scripts/ledger-check.sh` | all pass (see evidence block) | — |

**W1 findings (constitution rule 7 — recorded, not routed around):**

1. **The webapp's RPC client was already loopback.**
   `arcade-webapp.nix` `aria2RpcUrl` defaults to `http://127.0.0.1:6800/jsonrpc`
   — rebinding the daemon breaks nothing in the pipeline; the only
   loopback-breaking consumer was remote AriaNg via the tunnel (now the
   same-origin proxy + ledger W1-D1).
2. **The sudoers helpers live in `exodos.nix`, not `cartridges.nix`.**
   The plan's threat model named the cartridge plane; the actual NOPASSWD
   rules are the eXo extraction pair (`cartridges.nix` has no sudo path —
   its comment says so explicitly). Locked where they live.
3. **The retro metadata trees are separate ZFS datasets**, not "the same
   excluded dataset" the plan hedged on. Covered: `state` (important),
   `no-intro-dats` + `skyscraper-cache` (bulk). Deliberately still
   excluded: `metadata/pegasus*` (generated, regenerable,
   byte-equivalence-tested against the repo's golden corpus) — reasoning
   in `sanoid.nix`.
4. **`zfs-nas.nix`'s state-dataset comment was stale** (credited the
   removed arcade-inventory unit) — fixed in the same change; the snapshot
   rationale now names the real occupant.

**W1 residue (operator actions, not agent-executable):**

1. Deploy europa (`nixos-rebuild switch --target-host root@europa` from
   the operator path, or the CI dispatch): the aria2 unit restarts with
   the loopback bind + LoadCredential (verify with `ss -ltn | grep 6800`
   → 127.0.0.1 only, and `systemctl show aria2 -p LoadCredential`); the
   tunnel drops the rpc route at the same switch; sanoid starts
   snapshotting the three new datasets (verify with `sanoid --monitor-snapshots`-style
   `zfs list -t snapshot -o name -s creation | tail`).
2. Deploy the kiosks (amalthea, metis, adrastea, thebe) and callisto:
   the pinned sudoers rules replace the unlocked ones at switch. First
   eXo launch after the switch is the live check that the pinning accepts
   the real launch vectors (the fixture runs cover the same shapes; a
   failure would print the `die()` message, not hang the session).
3. Confirm in the Cloudflare dashboard that no other route still points
   at :6800 (the repo-side ingress is gone; DNS records for
   rpc.jupiter.au can be deleted whenever convenient — cloudflared now
   404s the hostname).
4. Remote AriaNg/RPC needs, if any, go through ledger W1-D1 (Cloudflare
   Access before the route returns).

---

## 8. W3 completion record — Lane G: the L3 browser lane

Approach: **chromium-in-VM**, as the plan's gate matrix names it — no
fallback to the lighter binary-only tier was needed. The pinned nixpkgs
(ffb3c9b7) ships in-tree Playwright packaging
(`pkgs/development/web/playwright` + `development/python-modules/playwright`);
the browser resolves through `PLAYWRIGHT_BROWSERS_PATH =
playwright-driver.browsers-chromium` (chromium channel only — no
firefox/webkit in the VM closure), exactly the wiring of nixpkgs' own
`nixos/tests/playwright-python.nix` at this pin. The chromium binary
substitutes from cache.nixos.org in ~44 s locally — no from-source
browser builds on the CI path. **No CDN fetch ever happens.**

The lane is a second `testers.runNixOSTest` (`checks.x86_64-linux.
arcade-webapp-browser-vm`) whose node imports the SAME L2 host file
(`tests/hosts/arcade-webapp-vm.nix` — real module, real igir/aria2,
deterministic fixture corpus) plus a `jupiter-arcade-webapp-browser`
service that runs the reviewed Playwright script
(`tests/browser/arcade-webapp-browser.py`) strictly AFTER the in-VM
smoke; the driver asserts BOTH verdicts. Contracts asserted: zero
4xx/5xx on every resource of every page (documents, polls, /art,
click XHRs); every htmx poll panel id exactly once in the live DOM
after at least one poll swap (non-vacuous guard: each polled fragment
must have been fetched before the scan); ≥1 mutating button click
(Rescan) whose POST response is not an error and whose request provably
carried htmx's native `HX-Request: true`; library renders ≥1 game card
with a decoded /art image.

| Task | Command | Result | Artefact |
|---|---|---|---|
| L3 check (green run) | `nix build -L --no-link .#checks.x86_64-linux.arcade-webapp-browser-vm` | **GREEN** — smoke PASS (2 min 34 s) then `ARCADE-WEBAPP-BROWSER: PASS` (50 s); `browser: Rescan click accepted (POST /rescan -> 202)`, `library renders 10 game card(s), art loaded`, `zero 4xx/5xx responses across every page, poll and click`; test script finished in 239.52 s | `tests/hosts/arcade-webapp-browser-vm.nix`, `tests/browser/arcade-webapp-browser.py`, `flake.nix` |
| **Negative test (the 403 class)** | temporarily reverted `hxRequestOK` to the original bug (accept ONLY `X-HX-Request` — the header htmx never sends), rebuilt the same check | **RED exactly as designed**: smoke stayed GREEN (`smoke: rescan accepted (HTTP 202, htmx-only)` → `ARCADE-WEBAPP-VM: PASS` — the forged-header blind spot, live) while the browser lane failed with `web: rejected mutation POST /rescan` + `ARCADE-WEBAPP-BROWSER: FAIL: mutating click POST /rescan -> 403 (the lifetime-403 class…)` + `FAIL: HTTP 403 on POST http://127.0.0.1:8094/rescan` (both probes: the click assertion AND the global 4xx tracker) | run log (serial + journal); break reverted byte-identical (`git diff` empty), green re-confirmed from the identical derivation `/nix/store/w5p5h4i4a4wxv2brh02mn74mlym2x8g6-vm-test-run-arcade-webapp-browser-vm.drv` |
| Flake eval gate | `nix flake check --no-build` | pass (check evaluates to `vm-test-run-arcade-webapp-browser-vm`) | `flake.nix` |
| Workflow lint | `nix run nixpkgs#actionlint .github/workflows/ci.yml` | clean for W3 additions; the one pre-existing shellcheck nit (SC2034, build-host unused loop var, documented in W0) remains, untouched | `.github/workflows/ci.yml` |
| Ledger | `./scripts/ledger-check.sh docs/plans/arcade-remediation-ledger.tsv` | OK — W3-A1 adoption row with dated gate-rot review | the ledger |
| nspawn contingency | design written | the degraded tier is a committed procedure (same host files, framework-native `containers` backend), switchable when the KVM probe fires — with its own negative-test re-proof required before trust | `docs/plans/arcade-l3-nspawn-contingency.md` |

**W3 findings (constitution rule 7 — recorded, not routed around):**

1. **The negative test reproduced the historical blind spot exactly.**
   With the original bug reintroduced, the ENTIRE L2 smoke stayed green
   (every curl forges `X-HX-Request`) and only the browser lane went
   red — a live demonstration of why the 403 lived undetected for the
   merged app's lifetime, and direct evidence the lane now guards the
   class. The fix's loud rejection logging (`web: rejected mutation
   POST /rescan from …`) also proved itself: the failure was named in
   the journal within seconds.
2. **Playwright's sync API does not dispatch event callbacks during
   `time.sleep()`** (run 1's false vacuous-poll failures). Every wait
   in the lane now goes through `page.wait_for_timeout`/`wait_for_*`
   so response/request events pump. Recorded here because it is the
   class of bug that would otherwise produce "flaky" greens later.
3. **This dev machine's nix config lists unreachable remote builders**
   (the kiosks), which stalls any first-real-build for tens of minutes
   in builder retries. The W3 runs used `--option builders ""`. Not a
   repo defect; flagged because the next implementer will hit it.

**W3 residue (operator actions, not agent-executable):**

1. Mark `arcade-webapp-l3-browser` as a **required status check** in
   branch protection alongside `check`, `arcade-webapp-l1` and
   `arcade-webapp-l2-vm` (W0 residue 1 still stands for the same
   reason: the YAML alone does not block merges).
2. Nothing else: the lane is CI-side only; no host deployment involved.
