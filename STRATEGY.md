---
name: jupiter-os
last_updated: 2026-07-13
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
| metis | kiosk (kitchen) | live |
| adrastea | kiosk (office) | live |
| thebe | kiosk (robbie-room) | live |
| europa | NAS + data hub | config staged (Phase 1 + Phase 2), awaiting physical install |
| pallene | build server (ephemeral ISO) | config staged, awaiting first run |

All 6 host configurations pass `make check` (`nix flake check --no-build`) and CI.

## Key metrics

- **Fleet Bootstrap Progress** - Number of fleet hosts successfully bootstrapped and running jupiter-os. Currently 4/10 live (kiosks); europa is the 5th and the current focus.
- **Requirement Adherence Rate** - Percentage of system requirements (storage profiles, secrets, core services) verified automatically via test VM boots or CI assertions. (Measured in CI/test runs).
- **LLM First-Pass Edit Success Rate** - Percentage of LLM-generated Nix changes that pass `make check` on the first run without introducing compilation slop. (Measured by git history / CI logs).

## Tracks

### Kiosk Fleet (complete)

The 4 TCx Wave dashboard kiosks are live under a shared `tcxwave-kiosk.nix` profile, with the robcoterm native client cutover on amalthea. This track validated the incremental, cache-first approach and the CI flake-check feedback loop. No active work.

### europa Phase 1 — Untuned NAS Bootstrap

Shrink the current Elementary OS partition, install JupiterOS on the OS SSD (stateful ZFS profile), and bring up the NAS untuned from `cache.nixos.org`: ZFS tank import + declarative datasets, Samba/NFS, Sanoid snapshots, Attic server, Syncthing, SMART monitoring.

_Why it serves the approach:_ Gets the NAS running with stock cached packages before anything depends on tuned binaries. Config is staged (PR #15); the physical install waits on the file transfer off the second disk completing.

**Status:** Config complete and CI-green. Blocked on: file transfer (sdc ext4 → tank) finishing, then the physical partition/install.

### europa Phase 2 — Tuned Closure Pipeline

Compile europa's closure targeted at its real CPU (`btver2`, Opteron X3216 Puma) on the ephemeral BinaryLane build server (`pallene`), push to europa's own Attic, and substitute back — the deliberate, mitigated exception to the stock-cache rule.

_Why it serves the approach:_ Recovers real performance on the weak NAS APU without invalidating the cache-first discipline: the private Attic cache exists precisely to serve what `cache.nixos.org` cannot once `gcc.arch` is set.

**Status:** Config complete and CI-green (PR #16, stacked on #15): `jupiter.build.microarch` option, build-server module, `pallene` ISO host, Cloudflare Tunnel on europa, substituter consumer wiring, `make pallene-iso`/`rebuild-world` targets. First run needs: real Cloudflare tunnel UUID, `attic cache create` to mint the substituter public key, and real BinaryLane/Attic tokens in sops.

### ZFS Mirror Completion

`tank` is currently a single vdev (one partition on the first 18 TB drive). The second drive is ext4, receiving the file transfer. Once it's empty, wipe it and `zpool attach` as a mirror.

_Why it serves the approach:_ Incrementally and safely reaches a redundant ZFS mirror without data loss — no risk to the live single-vdev pool until the second disk is verified empty.

**Status:** Blocked on the file transfer completing. Procedure documented in the europa Phase 1 plan appendix.

### Legacy Pool Integration

Reattach the legacy 10 TB ZFS archive pool disks and import read-only.

_Why it serves the approach:_ Safe, read-only access to legacy data so the fleet can transition without risking existing storage integrity.

**Status:** Deferred — the legacy drives aren't physically attached yet, and europa Phase 1 imports `tank` only.

## What's next after europa

Following the roadmap (`CLAUDE.md`): **ganymede** (resolver/services) → **callisto** (diskless PXE, consumes iSCSI from europa) → **himalia** (laptop) → gaming/branding/terranix/edge layers. Port each from the `master` design reference, keeping the buildability rules — no custom kernels on ZFS hosts, no microarch without a private cache to serve it.
