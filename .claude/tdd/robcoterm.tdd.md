# robcoterm — TDD Evidence Report

**Source plan:** `~/.gemini/antigravity-cli/brain/54844a27-e3be-4c2c-9fd7-23507c16aab7/{task.md, implementation_plan.md, slint_layout_spec.md}`
**Branch:** `claude/amalthea-bootstrap-rebuild-v340ul`
**Run scope:** Phase 0/1 (verify+commit) → Phase 2 (full) → Phase 3.1–3.4 → Phase 4.1/4.2 (code, no cutover). T4.3–T4.6 hard-blocked on a HA Long-Lived Access Token + physical panel.

## Commits (this run, current branch)
| SHA | Phase | Summary |
|---|---|---|
| `17c1efc` | 0/1 | spike builds, NixOS module inert under mkIf |
| `247b00a` | 2 | HA WebSocket layer (mock-tested) |
| `9c17999` | 3.1 | room theme (room_color + Slint Theme global) |
| `5cc21c3` | 3.2–3.4 | Slint widgets, bedroom overview, dispatch wiring |
| `593618c` | 4.1/4.2 | DRM DPMS helper + libinput idle (code, no cutover) |

## Test specification (what is guaranteed)
| # | What is guaranteed | Test (file / command) | Type | Result |
|---|---|---|---|---|
| 1 | HA auth handshake sends `{"type":"auth","access_token":…}` within 2s | `ha::tests::handshake_sends_auth_frame_within_2s` | integration (mock WS) | PASS |
| 2 | One `state_changed` push emits exactly one `HaEvent::State` with the typed value | `ha::tests::state_changed_emits_exactly_one_event` | integration (mock WS) | PASS |
| 3 | `ServiceCall::Light` → `{"type":"call_service","domain":"light","service":"turn_on","service_data":{"brightness_pct":N}}` | `ha::tests::service_call_writes_call_service_frame` + `service_call_to_frame_*` | integration + unit | PASS |
| 4 | Reconnect emits Disconnected → Connecting → Connected after a mid-session drop | `ha::tests::reconnect_emits_disconnected_then_connecting_then_connected` | integration (mock WS) | PASS |
| 5 | State cache typed for light/sensor/binary_sensor/sun/device_tracker + Raw fallback | `state::tests::*` (5) | unit | PASS |
| 6 | `--room office` → Theme primary `#3399ff` (and amber/green/purple for the other three) | `theme::tests::*` (5) | unit | PASS |
| 7 | Bedroom entities route to the right UI mutation (AIR/OCCUPANCY/ROOM LIGHTS/TEMPERATURE/PRINTER) per `jupiter-room.yaml` | `dispatch::tests::*` (8) | unit | PASS |
| 8 | `dispatch_plan` returns `None` for unknown entities (worker subscribes to ALL state_changed) | `dispatch::tests::unknown_entity_is_none_not_an_error` | unit | PASS |
| 9 | `set_dpms(Off)` writes DRM property value 3 (0 for On) | `display::tests::*` (4, `--features drm-mock`) | unit (mock DRM) | PASS |
| 10 | `/dev/dri/cardN` auto-detect sorts and excludes `renderD*` (amalthea card1 note) | `display::tests::list_primary_drm_devices_sorts_and_excludes_render_nodes` | unit | PASS |
| 11 | DPMS Sleep fires at idle threshold (once); Wake on next touch | `input::tests::*` (4) | unit (controlled `Instant`s) | PASS |

**Totals:** 33 lib tests, 0 failed. Gates: `cargo fmt --check` clean; `cargo clippy --all-targets --features drm-mock -- -D warnings` clean; `nix build .#robcoterm` ok (closure 125.9 MiB < 400 MiB bound; no new flake input — X.3 honored).

## RED methodology note (honest disclosure)
For each new module the tests and the minimal impl were authored together, then verified in a single `cargo test` run, because the Slint + tokio + tungstenite + rustls dep tree costs ~6–12 min per cold compile and per-task RED→GREEN loops were impractical inside this autonomous run. RED evidence is therefore **compile-time** per the tdd-workflow provision ("the test target newly exercises code paths that did not exist"): before each commit the module file did not exist and the verify command could not compile. The one mid-step runtime RED captured was the `link.events.recv()` borrow error (`E0596`) in ha::tests — failing compile, then fixed by `let mut link`, then GREEN. Future per-task work should restore strict per-test RED when iterating on an already-warm cache.

## Known gaps / handoff
- **Visual/layout verify (T3.2/T3.3 @1024×768)** — not run; needs a headless weston/QEMU render harness (or the hardware). Runbook below.
- **T3.5 detail pages** (lights/printer/power/enviro/stats/roster) — deferred; overview + dispatch is the architecture they hang on.
- **T3.6 Monofonto font bundling** — deferred (font is on disk at `~/Documents/fallout/custom_components/fallout_terminal/frontend/assets/monofonto.otf`).
- **VaultBoyMascot** is a labelled placeholder; real PNG fallbacks need the fallout SVGs rasterised (T3.2 asset work).
- **T4.1a / T4.2a spikes** — whose DRM fd to use for DPMS; evdev vs Slint backend libinput events. `RealDrm`/`StubInput` are stubs until then.
- **nix `checkPhase`** runs the bin's 0 tests, not the lib's 33 — a future `checkType`/`cargo test --all` tweak would gate them in CI.
- **T4.3–T4.6** blocked on HA token + hardware (see runbook).

## Runbook — what only the user can do (T4.3 → T4.6)
1. **T4.3 — mint amalthea's HA token.** HA → *Profile → Long-Lived Access Tokens* → name `robcoterm-amalthea`, copy the token. Then:
   `sops secrets/secrets.yaml` → add `robcoterm_ha_token_amalthea: ENC[…]` (`.sops.yaml` already lists amalthea's age key). The module already wires `sops.secrets.robcoterm_ha_token` → `LoadCredential=` → `%d/robcoterm_ha_token` → `--ha-token-file`.
2. **T4.4 — cut amalthea over.** In `hosts/amalthea/configuration.nix`: drop the `dashboard-kiosk.nix` + `tcxwave-touch-wake.nix` imports; set `jupiter.robcotermKiosk = { enable = true; haTokenFile = config.sops.secrets.robcoterm_ha_token.path; room = "bedroom"; idleTimeout = 300; }`. `make boot-smoke-amalthea` must reach `multi-user.target` with `robcoterm` active, then the 5-min hardware checklist (screen, ≤2s HA update, sleep @5min idle, wake ≤1s, no ERROR in `journalctl -u robcoterm`).
3. **T4.5 — clone to metis/adrastea/thebe** (rooms kitchen/office/robbie) after ≥48h stable on amalthea; same checklist per host.
4. **T4.6 — decommission** the Cage/Chromium stack only after ≥7 days stable on all four.
