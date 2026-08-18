# CLAUDE.md

Context for AI agents working in **jupiter-os** — a declarative, ZFS-backed
NixOS monorepo for the Jupiter home/lab infrastructure, currently being
**rebuilt from scratch one machine at a time**. `main` is the working trunk.
The previous full-fleet tree lives on the `archive/full-fleet-reference`
branch and serves as the design reference; it was never buildable end-to-end
(see README.md for why). Do not copy code from it wholesale — port pieces
only when the machine that needs them is brought up.

## Current state

> ⚠️ **Staleness:** *git-committed* config, not live hosts — verify liveness
> empirically (ping/ssh); >~30 days may be stale. History: `docs/host-bringup-history.md`.

### STATUS

| Host | Role / IP | State | Verified |
|---|---|---|---|
| `amalthea` | kiosk — bedroom (bootstrap template) | ✅ live | — |
| `metis` | kiosk — kitchen | ✅ live | 2026-07-24 |
| `thebe` | kiosk — robbie-room | ✅ live | — |
| `adrastea` | kiosk — office | registered/CI-green; placeholder disk (`REPLACE-ME`) + age key, awaiting install | — |
| `europa` | `10.1.1.2` — ZFS NAS + data hub + PXE | ✅ live; **microarch tuning disabled 2026-08-13** (commented out, substitutes from cache.nixos.org) | — |
| `callisto` | `10.1.1.3` — shared builder + MQTT broker | ✅ live; iSCSI root on europa zvol; **microarch tuning disabled 2026-08-13** (still advertises `gccarch-*` to BUILD for others) | 2026-07-24 |
| `pallene` | Kamatera VPS build server (not fleet) | persistent, disk-booted via `.#pallene-raw` | — |

`.sops.yaml` also holds `ganymede`/`himalia` age keys (roadmap, not in
`flake.nix`). Kiosks share `modules/desktop/tcxwave-kiosk.nix` (per-host
hostName/hostId/dashboard URL/disk); callisto has no DNS/MDNS, so cross-host
refs (MQTT, builds) dial it by IP.

### TOPOLOGY — cross-host wiring

- **MQTT → callisto `10.1.1.3`** (`modules/services/mqtt.nix`): kiosk ha-agents + Home Assistant → mosquitto (static `mqttHost`).
- **Build delegation → callisto** (`modules/core/build-machines.nix`, **currently disabled fleet-wide** — commented out of `common.nix`, no host enables it; europa delegates inline to callisto only via `nix.buildMachines`). When enabled it advertises `gccarch-bdver4`/`skylake`; callisto keeps those adverts (what it can build FOR OTHERS) even though its own closure is no longer tuned. CI (not pallene) builds the tuned closures and pushes them to Harmonia over the tailnet (Attic decommissioned — #63). The old pallene push path (`modules/services/build-server.nix`) is orphaned.
- **PXE netboot → europa** (`modules/network/pxe-server.nix` via `flake.nix` `pxeModule`): serves callisto's netboot — ganymede's old role (same deviation as `cloudflareTunnel`). **Deliberately half-decoupled:** europa's closure holds only the static iPXE binaries (TFTP); the callisto-derived `boot.ipxe`/`bzImage`/`initrd` are the standalone `.#pxe-netboot-assets` package, published into `/var/lib/pxe-netboot/current` by `jupiter-pxe-assets.service` and served over HTTP — so building europa never builds callisto. `boot.ipxe` pins `init=` to a callisto toplevel, so the publish step must run **after** callisto has switched to that generation (the path has to exist on callisto's iSCSI root).
- **Harmonia → europa** (`services.harmonia` on `:5000`): read-only binary cache serving europa's `/nix/store`. GitHub Actions builds the closures on free `ubuntu-latest` CPU (as of 2026-08-13 only the kiosks are still `skylake`-tuned; europa/callisto substitute from cache.nixos.org) and pushes them over the tailnet (`nix copy --to ssh://europa` as `jupiter-ci`, **main-only**, incremental via a post-build-hook, last 3 main builds/host pinned as GC roots) — see `docs/ci-harmonia-push-runbook.md`. Replaces the decommissioned Attic (#63).

## Layout

- `flake.nix` — entry point. Inputs are deliberately minimal (nixpkgs,
  `nixpkgs-unstable` floated free so `modules/core/crush.nix` can pull a newer
  Go toolchain than the fleet pin, disko, impermanence, sops-nix,
  ha-linux-agent, `jovian` for the kiosks' gaming stack, `suno-web` for
  europa's Suno-archive browser). `mkHost` injects flake modules via a lexical
  closure — avoid `specialArgs`. Every host in `nixosConfigurations` is also a
  flake check.
- `hosts/<name>/` — per-host config (`configuration.nix`). Hosts are named
  after Jupiter's moons.
- `modules/` — reusable NixOS modules behind a `jupiter.*` options namespace,
  organized into category subdirs (`boot/`, `core/`, `desktop/`, `gaming/`,
  `network/`, `services/`, `storage/`). `common.nix` at the `modules/` root is
  the base layer.
- **jupiterOS Arcade** (partial, in-tree) — europa runs the cartridge-ROM
  pipeline (`modules/services/rom-acquire.nix`, `rom-scraper.nix`,
  `arcade-inventory.nix`: bulk-stage via Minerva torrents, igir-verify,
  Skyscraper-scrape into Pegasus metadata, emit inventory JSON); kiosks
  consume the results read-only over NFS and mount the eXo DOS/Win3x
  collections (`modules/desktop/exodos.nix`).
  `modules/gaming/console.nix` is the Bazzite-style Jovian gaming stack
  (gamescope "gaming mode", Steam, peripherals) the kiosks flip into via
  `modules/desktop/dashboard-gaming.nix`.
- `secrets/secrets.yaml` — sops-nix + age. Recipients (one age key per host
  plus the admin key) are listed in `.sops.yaml`. Carried over unchanged from
  the previous tree.

## Conventions

- New cross-host functionality goes in a `modules/<category>/` file gated by
  a `jupiter.*` option; hosts opt in via toggles rather than inlining config.
- **Module style:** explicit `lib.mkOption` / `lib.mkIf` / `lib.types`, never
  `with lib;`; argument order `{ config, lib, pkgs, ... }`; structure each
  module as `options.jupiter.<…> = { … }` then
  `config = lib.mkIf cfg.enable { … }` with `cfg = config.jupiter.<…>` bound
  in a `let`.
- **Buildability rules (the reason this rebuild exists):**
  - No custom kernels on ZFS hosts — the stock `linuxPackages` default is
    the one ZFS always supports and cache.nixos.org always has built.
  - A new flake input must be justified by a registered host that uses it.
  - No cross-host closure wiring (PXE, backup-hub scans) until both ends of
    the wire are registered and building.
  - **No global `nixpkgs.overlays` entry that rewrites `stdenv` or otherwise
    perturbs every derivation.** `doCheck` and friends are part of the
    derivation, so a blanket override changes the output hash of every package
    that sets them *and everything downstream* — zlib is one, so it cascades to
    the whole closure and cache.nixos.org matches nothing. A `doCheck = false`
    overlay of exactly this shape lived here until 2026-08-13 and cost europa
    2244 local builds where 70 was correct (measured, `nix build --dry-run`
    with the overlay as the only variable). Override the one package that
    misbehaves — `bmake = prev.bmake.overrideAttrs { doCheck = false; }` — never
    the stdenv.
- Everything must keep building from cache.nixos.org (`nix flake check`). A
  host that sets `jupiter.build.microarch` emits derivations tagged with
  `requiredSystemFeatures=["gccarch-<arch>"]` — those need the matching
  system-feature + the private Attic substituter to actually build, but `nix
  flake check` is eval-only and never realizes derivations, so `make check`
  (it runs `--no-build`) stays green fleet-wide and is the fast local path.
- sops secrets are read at **activation**, not build time — `nix build`, CI,
  and `nix flake check` work without the age key.
- **Find the accepted "modern method" first.** Before wiring up any NixOS
  service/module — especially anything with several evolving approaches
  (secrets, networking/wifi, NetworkManager, sops integration) — **use
  `parallel-search` / `parallel-fetch` for the current canonical method** (e.g.
  nixpkgs option docs, discourse, upstream module READMEs, release notes) and
  use it. Do not reverse-engineer a mechanism from first principles, copy a
  stale pattern from the archive branch, or hand-roll a workaround (a racy
  envsubst/systemd hack, a plaintext fallback, etc.) when nixpkgs already
  ships the blessed option. Hard-won example: thebe wifi PSK must go through
  `networking.networkmanager.ensureProfiles.secrets` (the `nm-file-secret-agent`
  D-Bus secret agent), NOT an `environmentFiles` + `envsubst` + custom service
  pipeline.
- **Stay bleeding-edge with parallel tools.** Training data is stale. For any
  question about current language versions (Rust 1.97, Go 1.26, NixOS 26.11),
  recent CVEs, pre-release features, or evolving best practices — **use
  `parallel-search` with dated queries** (e.g. "Rust 1.97 release notes 2026",
  "Go 1.26.6 August 2026", "NixOS 26.11 pre-release") and `parallel-fetch` to
  pull official release notes. Batch related queries in one call. The parallel
  tools hit live sources (project blogs, GitHub releases, Hydra, discourse)
  and return precisely dated, authoritative results — verified working as of
  August 2026.
- **Git:** always `git push` after committing — the user wants every commit
  pushed to the remote immediately, no holding locally. Commit messages
  reference any GitHub issue/PR found during the work and include a section
  on why the work was started (see personal `~/.claude/CLAUDE.md`).
- **Deploying to a host:** ALWAYS `ssh root@<host>` and run
  `nixos-rebuild switch --flake github:belikh/jupiter-os#<host>` ON the host
  itself. Root SSH works on every host; `io` has no passwordless sudo, so do
  NOT use `io`+sudo or `--target-host`/`--use-remote-sudo` from a laptop. The
  host pulls the flake straight from GitHub (`github:belikh/jupiter-os` tracks
  `origin/main`), so a change MUST be committed + pushed before it is
  deployable. Untuned hosts substitute their whole closure from
  cache.nixos.org (no heavy local compile), which is why on-host `switch` is
  safe even on the 7.6GB kiosks; microarch-tuned hosts that can't substitute
  build on callisto/pallene and push to attic first, then `switch` substitutes
  from there. Verify by observation afterward (read the changed file/state on
  the host, restart the relevant service), never by assertion.

## Fable-Domain: Jupiter-OS Infrastructure Workflow

Use the **fable-domain for jupiterOS** to approach infrastructure changes safely and efficiently. The domain captures the 7 most tempting mistakes developers make (custom kernels on ZFS hosts, unjustified flake inputs, secrets read at build time, etc.) and structures a 9-step workflow that prevents them:

1. **Classify & scope** the change (which hosts, what consequence)
2. **Establish host state empirically** (ping/ssh, check sops keys for real vs placeholder)
3. **SEARCH the internet for the modern canonical method** ← Key discipline; do not hand-roll
4. **Locate module extension point** and read house-style skeleton
5. **Check cross-host wiring gates** (both ends registered and building?)
6. **Write module in style** and test with `make check`
7. **Verify secrets are activation-time only** (gated by real age key)
8. **Deploy and verify by observation** (not by assertion — restart services, passively poll, clean reboot)
9. **Commit, push, and report outcome-first**

Each step has explicit gates that block before deployment. Reference: `references/domains/jupiterOS.md` (full workflow + flowchart + fraud prevention table). Trap fixture in `eval/scenarios/jupiterOS-trap/GROUND-TRUTH.md`.

Key memories that drove this workflow: `jupiter_os_thebe_wifi_sae_fix.md`, `jupiter_os_pallene_push_path.md`, `jupiter_os_kiosk_build_oom.md`, `jupiter_os_nm_autoconnect_vs_connection_up.md`, `jupiter_os_test_dont_assert.md`.

## Common commands

```bash
make check              # nix flake check --no-build (eval every registered host)
make build-all          # build the 4 kiosk closures (skylake-tuned)
make test-<host>        # build & boot a host in a QEMU VM
make boot-smoke-<host>  # headless CI-style boot test
make fmt                # format all Nix (nixfmt-rfc-style); fmt-check to verify

# Deploy a host (run ON the target host, as root, from the pushed GitHub flake;
# commit + push BEFORE deploying — the host pulls github:belikh/jupiter-os).
# For live progress, pipe nix's internal-json log through nom
# (nix-output-monitor, fleet-wide via modules/common.nix — no install step).
# There is NO `nom os-switch`: nom only wraps build/shell/develop/copy/flake,
# so nixos-rebuild has to be piped in by hand. internal-json carries the
# per-derivation activity nom's table is built from at *any* verbosity (only
# `msg` lines are verbosity-filtered) — adding -v just layers
# nixos-rebuild-ng's own `debug:` lines on top, which nom passes through.
# `|&` is bash — keep the pipe inside the quotes when dialing in from fish.
ssh -t root@<host> 'nixos-rebuild switch --flake github:belikh/jupiter-os#<host> \
  --log-format internal-json |& nom --json'
# Plain, no nom (26.11 is nixos-rebuild-ng; --fast is deprecated → --no-reexec):
ssh root@<host> -- nixos-rebuild switch --flake github:belikh/jupiter-os#<host>
```

## Roadmap (bring-up order)

amalthea + thebe (live) → the remaining 2 kiosks (metis/adrastea —
registered, CI-green, awaiting physical install) → europa (live,
untuned since 2026-08-13) → callisto
(registered CI-green, **live with iSCSI root**, **skylake-tuned**, fleet
build server) →
ganymede (resolver/services) → himalia (laptop) → gaming/branding/terranix/
edge layers. Port each from `archive/full-fleet-reference`, keeping the
buildability rules above.
