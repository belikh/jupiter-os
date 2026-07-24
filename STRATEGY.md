---
name: jupiter-os
last_updated: 2026-07-20
---

# jupiter-os Strategy

## Target problem

We cannot bootstrap or manage our home lab fleet until our main NAS host (which runs always-on services and holds credentials) is safely partitioned and booted into JupiterOS. At the same time, the NixOS configuration must be structured so LLM agents can configure and maintain the systems cleanly without introducing configuration slop or breaking compilation.

## Our approach

Start from the smallest host and grow the fleet incrementally, using stock cached NixOS packages/kernels to avoid custom compilation, and validating every host configuration via flake checks so LLMs have a fast feedback loop.

The kiosk fleet (4 TCx Wave units) validated this approach end-to-end. europa (the NAS) extends it with a deliberate two-phase pattern: Phase 1 bootstraps untuned from `cache.nixos.org` so the box is running before anything depends on it; Phase 2 layers a CPU-tuned closure served from europa's own private Attic cache — the one justified exception to the "stock cached packages" rule, mitigated by the build-server pipeline.

## Who it's for

**Primary:** Home Lab Administrator - They are hiring jupiter-os to declaratively configure their entire computing infrastructure (servers, desktops, automations, networking) with LLM assistance, without writing any Nix configuration code themselves.

## Current fleet state

| Host | Role | Status |
|------|------|--------|
| amalthea | kiosk (bedroom) | live |
| thebe | kiosk (robbie-room) | live |
| metis | kiosk (kitchen) | registered; awaiting physical install (placeholder disk + sops key) |
| adrastea | kiosk (office) | registered; awaiting physical install (placeholder disk + sops key) |
| europa | NAS + data hub, PXE server for callisto | live at `10.1.1.2`, full Phase 2 `btver2`-tuned closure, substituted from its own Attic |
| callisto | diskless netboot, fleet Nix remote builder + MQTT broker (HP EliteDesk 800 G4 DM, i5-8500T Coffee Lake 6c/6t, 64GB RAM) | live at `10.1.1.3` on a kexec-netboot closure; daemon tuning (`cores=6 max-jobs=1`) committed, `jupiter.build.microarch = "skylake"` is a roadmap entry awaiting a pallene build/push |
| pallene | build server (ephemeral ISO) | proven end-to-end — built and pushed europa's Phase 2 closure via `make rebuild-world` |

All 7 host configurations pass `make check` (`nix flake check --no-build`) and CI.

## Key metrics

- **Fleet Bootstrap Progress** - Number of fleet hosts successfully bootstrapped and running jupiter-os. Currently 2/10 live (amalthea kiosk + europa untuned NAS); 3 kiosks registered but not yet installed; europa tuned closure (Stage 4) is the current focus.
- **Requirement Adherence Rate** - Percentage of system requirements (storage profiles, secrets, core services) verified automatically via test VM boots or CI assertions. (Measured in CI/test runs).
- **LLM First-Pass Edit Success Rate** - Percentage of LLM-generated Nix changes that pass `make check` on the first run without introducing compilation slop. (Measured by git history / CI logs).

## Tracks

### Kiosk Fleet (mostly complete)

The 4 TCx Wave dashboard kiosks share a `tcxwave-kiosk.nix` profile. amalthea
is live as the bootstrap host (each kiosk's ha-agent publishes to the fleet
MQTT broker, which now runs on callisto rather than amalthea). The 3
siblings are registered and CI-green but still on placeholder disks and sops
keys — physically installing them is a mechanical task, not a config one.
This track validated the incremental, cache-first approach and the CI
flake-check feedback loop.

### europa Phase 1 — Untuned NAS Bootstrap ✅ DONE

Shrank the Elementary OS partition, installed JupiterOS on the OS SSD
(stateful ZFS profile), and brought up the NAS untuned from
`cache.nixos.org`: ZFS tank import + declarative datasets, Samba/NFS, Sanoid
snapshots, Attic server, Syncthing, SMART monitoring.

_Why it serves the approach:_ Got the NAS running with stock cached packages
before anything depended on tuned binaries. Europa is live at `10.1.1.2` on
the Phase 1 closure (commit on `main`).

### europa Phase 2 — Tuned Closure Pipeline (in progress)

Compile europa's closure targeted at its real CPU (`btver2`, Opteron X3216
Puma) on the ephemeral BinaryLane build server (`pallene`), push to europa's
own Attic, and substitute back — the deliberate, mitigated exception to the
stock-cache rule.

_Why it serves the approach:_ Recovers real performance on the weak NAS APU
without invalidating the cache-first discipline: the private Attic cache
exists precisely to serve what `cache.nixos.org` cannot once `gcc.arch` is
set.

**Status:** Stage 3 prerequisites done (real Cloudflare tunnel UUID, attic
cache + public key, R2 creds, BinaryLane/Attic tokens all committed). Stage
4 first end-to-end `rebuild-world` run is in progress: initial attempts
self-destructed without pushing; root causes found and fixed (nix-command
flakes experimental feature missing on the mkIsoHost, hostname dep, R2 SigV4
presign, attic cache visibility, push token scope). The fixed ISO is
locally validated in QEMU and the next BinaryLane run is de-risked. See
`docs/europa-stage4-progress.md` for the live log.

### ZFS Mirror Completion ✅

`tank` is now a 16.4 T two-disk mirror across the WD 18 TB drives, using
whole-disk vdevs (ZFS-managed GPT — pool members addressed by-id with no
`-partN` suffix, so `zpool replace` can rebuild the layout on a fresh disk
with no manual partitioning). Built 2026-07-20 via the attach-then-grow
sequence: Phase 1 attached sdc as a whole-disk mirror of the legacy sda1
partition (which had been hand-created at 8.2 T, wasting half of sda); Phase 2
detached sda1, wiped sda, and re-attached it as a second whole-disk vdev. The
migration also doubled the pool's logical capacity (8.17 T → 16.4 T) and
enabled all OpenZFS 2.4.3 feature flags.

_Why it served the approach:_ Incrementally and safely reached a redundant
ZFS mirror without data loss — the pool was redundant throughout, except for
the brief degraded window in Phase 2 between detaching sda1 and re-attaching
sda as a whole disk (a minute of commands; the just-resilvered sdc held a
complete, verified copy of the 2 T of data during that window).

**Status:** Done. Procedure and history in
`docs/europa-bringup-stages.md` Stage 2.

### Legacy Pool Integration

Reattach the legacy 10 TB ZFS archive pool disks and import read-only.

_Why it serves the approach:_ Safe, read-only access to legacy data so the fleet can transition without risking existing storage integrity.

**Status:** Deferred — the legacy drives aren't physically attached yet, and europa Phase 1 imports `tank` only.

## What's next after europa

Following the roadmap (`CLAUDE.md`): **callisto** (diskless netboot, fleet Nix remote builder — registered, awaiting physical netboot test) → **ganymede** (resolver/services) → **himalia** (laptop) → gaming/branding/terranix/edge layers. Port each from the `archive/full-fleet-reference` design reference, keeping the buildability rules — no custom kernels on ZFS hosts, no microarch without a private cache to serve it.
