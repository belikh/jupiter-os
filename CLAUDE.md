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
| `europa` | `10.1.1.2` — ZFS NAS + data hub + PXE | ✅ live, **untuned** (btver2 rolled back) | — |
| `callisto` | `10.1.1.3` — shared builder + MQTT broker | ✅ live; iSCSI root on europa zvol; `skylake` microarch roadmap-only | 2026-07-24 |
| `pallene` | Kamatera VPS build server (not fleet) | persistent, disk-booted via `.#pallene-raw` | — |

`.sops.yaml` also holds `ganymede`/`himalia` age keys (roadmap, not in
`flake.nix`). Kiosks share `modules/desktop/tcxwave-kiosk.nix` (per-host
hostName/hostId/dashboard URL/disk); callisto has no DNS/MDNS, so cross-host
refs (MQTT, builds) dial it by IP.

### TOPOLOGY — cross-host wiring

- **MQTT → callisto `10.1.1.3`** (`modules/services/mqtt.nix`): kiosk ha-agents + Home Assistant → mosquitto (static `mqttHost`).
- **Build delegation → callisto** (`modules/core/build-machines.nix`, default-on): advertises `gccarch-btver2`/`skylake` to build *others'* tuned closures while its own stays untuned; `cores=6 max-jobs=1`. Pallene inverts it (`cores=1 max-jobs=auto`) and pushes tuned closures to the Harmonia cache (Attic decommissioned — #63; pallene's push path is dormant pending a `nix copy` rework, see `modules/services/build-server.nix` header).
- **PXE netboot → europa** (`modules/network/pxe-server.nix` via `flake.nix` `pxeModule`): serves callisto's netboot — ganymede's old role (same deviation as `cloudflareTunnel`).
- **Harmonia → europa** (`services.harmonia` on `:5000`): read-only binary cache serving europa's `/nix/store`. GitHub Actions builds the kiosk closures on free `ubuntu-latest` CPU and pushes them in over the UDM WG road-warrior (`nix copy --to ssh://europa` as `jupiter-ci`, **main-only**, incremental via a post-build-hook, last 3 main builds/host pinned as GC roots) — see `docs/ci-harmonia-push-runbook.md`. Replaces the decommissioned Attic (#63).

## Layout

- `flake.nix` — entry point. Inputs are deliberately minimal (nixpkgs,
  `nixpkgs-unstable` floated free so `modules/core/crush.nix` can pull a newer
  Go toolchain than the fleet pin, disko, impermanence, sops-nix,
  ha-linux-agent, `jovian` for the kiosks' gaming stack). `mkHost` injects
  flake modules via a lexical closure — avoid `specialArgs`. Every host in
  `nixosConfigurations` is also a flake check.
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
  (secrets, networking/wifi, NetworkManager, sops integration) — **websearch
  for the current canonical method** (e.g. nixpkgs option docs, discourse,
  upstream module READMEs) and use it. Do not reverse-engineer a mechanism
  from first principles, copy a stale pattern from the archive branch, or
  hand-roll a workaround (a racy envsubst/systemd hack, a plaintext fallback,
  etc.) when nixpkgs already ships the blessed option. Hard-won example: thebe
  wifi PSK must go through `networking.networkmanager.ensureProfiles.secrets`
  (the `nm-file-secret-agent` D-Bus secret agent), NOT an `environmentFiles` +
  `envsubst` + custom service pipeline.
- **Git:** always `git push` after committing — the user wants every commit
  pushed to the remote immediately, no holding locally.
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
make build-all          # build the 4 kiosk closures (the untuned hosts)
make test-<host>        # build & boot a host in a QEMU VM
make boot-smoke-<host>  # headless CI-style boot test
make fmt                # format all Nix (nixfmt-rfc-style); fmt-check to verify

# Deploy a host (run ON the target host, as root, from the pushed GitHub flake;
# commit + push BEFORE deploying — the host pulls github:belikh/jupiter-os):
ssh root@<host> -- nixos-rebuild switch --flake github:belikh/jupiter-os#<host>
```

## Roadmap (bring-up order)

amalthea + thebe (live) → the remaining 2 kiosks (metis/adrastea —
registered, CI-green, awaiting physical install) → europa (live, untuned —
`btver2` rolled back pending a ZFS/nixpkgs fix) → callisto
(registered CI-green, **live with iSCSI root**, fleet build server) →
ganymede (resolver/services) → himalia (laptop) → gaming/branding/terranix/
edge layers. Port each from `archive/full-fleet-reference`, keeping the
buildability rules above.
