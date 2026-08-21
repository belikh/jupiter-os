# jupiterOS stack guide — languages, frameworks, topology

Status: DRAFT v0.1 for owner review · 2026-08-22
Companion to [style-guide.md](./style-guide.md) (ZEUS design language): that file
governs how jupiterOS *looks*; this file governs what jupiterOS *is built with*.
Where they overlap, both agree: server-rendered web, plain CSS custom properties,
no SPA frameworks, ever.

---

## 1. Topology principles

- **callisto is the serving host.** The unified platform, Postgres, the MQTT broker,
  and delegated builds live here. Everything user-facing is served from callisto.
- **europa is the NAS. Storage only.** No new services land on europa.
  Fileserver apps belong here by definition — Harmonia (binary cache serving
  `/nix/store` over HTTP) is exactly that, so it stays on europa permanently,
  not as an exception.
- **Cloudflare Tunnel is the perimeter.** Services bind locally; exposure happens
  through tunnels with Cloudflare Access in front. Auth-at-the-edge is the default;
  apps add their own auth only when they need identities finer than Access provides.
- **Kiosks are thin web clients.** A kiosk screen is a fullscreen browser pointed at
  the unified system. Pegasus/QML exists for gaming mode only (§6).

## 2. The unified platform

One destination absorbs everything: arcade management, suno archive browsing, wall
dashboards (Home Assistant included), future apps.

- **Shape: modular core.** One core platform owns layout, navigation, ZEUS token
  serving, and access assumptions; apps are registered modules compiled into it
  (`/arcade`, `/suno`, `/home`, …). Starts as one deployable; may split later only
  if a module demonstrably needs it.
- **Home Assistant: API-first absorb.** The platform calls HA's REST/WebSocket API
  as its data source and renders Zeus views over it. Lovelace views are replaced
  opportunistically; end state is HA headless — a service, not a surface.
- **No rewrite cliff.** Existing tools (arcade-webapp, suno-web, hasstui) keep
  working while their functions migrate into modules; absorption is incremental.

## 3. Language roster

| Domain | Language / tool | Notes |
|---|---|---|
| Apps, APIs, CLIs, TUIs | **Go** | html/template for web; charm stack for TUIs |
| OS configuration | **Nix** | `jupiter.*` module namespace, house style per CLAUDE.md |
| Glue scripts | **Bash** | §7 threshold |
| Wall dashboards | **HTML/CSS served by the platform** | consumed by kiosk browsers |
| Gaming-mode themes | **QML** (Pegasus) | bounded to theme files; no app logic lives here |
| Database | **SQL** (Postgres) | §5 |

Banned outright:

- **React, Svelte, Vue, and SPA frameworks of any kind** — burned twice, rejected
  twice. Server-rendered HTML is the product.
- **SQLite** — avoided everywhere, including "just embedded" use. New state goes to
  Postgres. (Rationale: one database to back up, tune, and reason about; fleet-wide
  Postgres on callisto is being stood up now.)
- **Node/npm as a build dependency.** No `node_modules` anywhere in the flake.
- **New languages** (Python, Rust, Lua-as-logic, …) require this document changing
  first — same rule as the style guide's change process.

## 4. Web rules

- **Rendering:** Go `html/template`, partials over full pages. The template tree is
  the component system.
- **Styling:** plain CSS custom properties consuming ZEUS `--ze-*` tokens from a
  static `zeus-tokens.css`. No preprocessor, no Tailwind, no build step. Fonts
  self-hosted woff2.
- **Client JS: per-app choice** within hard limits — htmx, Alpine, or hand-rolled
  vanilla are all acceptable; whatever lands must be a vendored static file pinned
  by hash (htmx in arcade-webapp is the precedent), must work without a bundler,
  and must degrade to usable HTML when JS fails. No transpiled client code.
- **Serving:** behind Cloudflare Tunnel; bind to localhost/LAN only.

## 5. Data rules

- **Postgres is canonical.** App state, dashboards config, user prefs: tables on
  callisto. One cluster, one backup story (restic), schema migrations owned by the
  module that introduced them.
- **Files are artifacts, not truth.** Generated/exported things — arcade inventory
  JSON, scraped Pegasus metadata, ROM trees — live on disk where the pipeline needs
  them, but the database records what matters about them. If a file and its row
  disagree, the row wins and regeneration fixes the file.
- **MQTT streams; Postgres stores.** MQTT on callisto remains the house event bus
  (presence, sensors, kiosk chatter, automation triggers). Apps subscribe for
  reactions and persist anything they'll need later into Postgres. Nothing
  long-lived lives only in a broker topic.

## 6. TUI rules

- charm stack, non-negotiable: **bubbletea** (runtime), **lipgloss** (styling),
  **bubbles** (components), **huh** (forms). hasstui is the reference
  implementation.
- Styling uses lipgloss colors mapped from ZEUS phosphor tokens (truecolor first,
  colorprofile degradation handles the rest).
- Borders stay square (`NormalBorder`/`ThickBorder`) — geometry is boxy everywhere.

## 7. Bash threshold

Bash is glue: piping, invoking, wiring — target under ~100 lines, no real parsing
beyond grep/awk one-liners, no state machines, no JSON munging beyond `jq`. A
script that outgrows that becomes a Go subcommand or a module feature in the same
change that proves it outgrew it. systemd units prefer plain ExecStart over wrapper
scripts; when a wrapper is unavoidable it follows the same threshold.

## 8. Toolchain & dependencies

- **Go: single hard pin** from nixpkgs, fleet-wide. Every Go derivation builds with
  the same toolchain; bumping the pin is a deliberate, repo-wide commit — never a
  per-package escape hatch. Known debt: `crush` currently overrides with a newer Go
  from unstable (`modules/core/crush.nix`); it collapses onto the pin at the next
  bump rather than propagating the pattern.
- **Vendored third-party assets** (htmx, AriaNg): allowed, stored in-tree or fetched
  by fixed hash in Nix, updated by deliberate commits. Never pulled at runtime,
  never via package managers.
- **Flake inputs** follow the existing buildability rule: justified by a registered
  host that uses them.

## 9. Packaging & verification

- Everything ships as a flake package or NixOS module; `nix flake check` stays
  green (eval-only) — `make check` is the fast gate.
- Go code: `go test ./...` green per module before merge; VM smoke tests
  (`tests/hosts/*-vm.nix`, `make test-<host>` / `make boot-smoke-<host>`) cover
  anything that claims to run as a service.
- Web changes get verified against the ZEUS preview discipline: rendered output
  seen, not asserted.

## 10. Change process

Same rule as the style guide: this document changes first, code second. A PR that
introduces a banned framework, a SQLite file, a new language, or an unpinned asset
is rejected on sight regardless of how well it works. Exceptions cost a paragraph
here explaining why the rule was wrong.
