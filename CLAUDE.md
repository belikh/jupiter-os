# CLAUDE.md

Context for AI agents working in **jupiter-os** — a declarative, ZFS-backed
NixOS monorepo for the Jupiter home/lab infrastructure, currently being
**rebuilt from scratch one machine at a time**. `main` is the working trunk.
The previous full-fleet tree lives on the `archive/full-fleet-reference`
branch and serves as the design reference; it was never buildable end-to-end
(see README.md for why). Do not copy code from it wholesale — port pieces
only when the machine that needs them is brought up.

## Current state

Registered hosts: the 4 TCx Wave dashboard kiosks — `amalthea`
(jupiter-bedroom, the bootstrap machine, canonical template, and the fleet's
MQTT broker), `metis` (kitchen), `adrastea` (office), `thebe` (robbie-room) —
plus `europa` (HPE MicroServer Gen10, the ZFS NAS + data hub) and `pallene`
(ephemeral BinaryLane build-server ISO host, phase2 only). `amalthea` and
`thebe` are physically installed today; `metis` and `adrastea` are registered
and CI-green but still on placeholder disks/sops keys, awaiting their real
install (see `.sops.yaml`). The siblings are clones of amalthea minus the
broker role, differing in hostName/hostId/dashboard URL/disk.

**europa bring-up:** Stage 4 is **done** — europa is running its full
`btver2`-tuned closure, substituted from its own Attic (`attic.jupiter.au` /
the `neptune.jupiter.au:8080` port-forward). See `docs/europa-bringup-stages.md`
for the full runbook and history; remaining stages (2 — ZFS mirror, 5 —
deferred items) are independent cleanup, not blockers.

Everything must keep building from cache.nixos.org with `nix flake check`
(note: europa's `btver2` closure substitutes only from europa's own Attic, not
cache.nixos.org — `nix flake check` still works fleet-wide since it's
eval-only and doesn't realize derivations; `make check` remains the fast
no-build path for local iteration).

## Layout

- `flake.nix` — entry point. Inputs are deliberately minimal (nixpkgs, disko,
  impermanence, sops-nix, ha-linux-agent). `mkHost` injects flake modules via
  a lexical closure — avoid `specialArgs`. Every host in
  `nixosConfigurations` is also a flake check.
- `hosts/<name>/` — per-host config (`configuration.nix`). Hosts are named
  after Jupiter's moons.
- `modules/` — reusable NixOS modules behind a `jupiter.*` options namespace,
  organized into category subdirs (`boot/`, `core/`, `desktop/`, `network/`,
  `services/`, `storage/`). `common.nix` at the `modules/` root is the base
  layer.
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
  - No microarch tuning (`nixpkgs.hostPlatform.gcc.arch`) — it invalidates
    the binary cache for the entire closure.
  - A new flake input must be justified by a registered host that uses it.
  - No cross-host closure wiring (PXE, backup-hub scans) until both ends of
    the wire are registered and building.
- sops secrets are read at **activation**, not build time — `nix build`, CI,
  and `nix flake check` work without the age key.
- **Git:** always `git push` after committing — the user wants every commit
  pushed to the remote immediately, no holding locally.

## Common commands

```bash
make check              # nix flake check --no-build (eval every registered host)
make build-all          # build the 4 kiosk closures (the untuned hosts)
make test-<host>        # build & boot a host in a QEMU VM
make boot-smoke-<host>  # headless CI-style boot test
make pallene-iso        # build the disposable build-server ISO
make rebuild-world      # full ephemeral build-server run: ISO → R2 → BinaryLane → attic
make fmt                # format all Nix (nixfmt-rfc-style); fmt-check to verify
```

## Roadmap (bring-up order)

amalthea + thebe (live) → the remaining 2 kiosks (metis/adrastea —
registered, CI-green, awaiting physical install) → europa (live, full
`btver2` tuned closure — see `docs/europa-bringup-stages.md`) → ganymede
(resolver/services) → callisto (diskless PXE) → himalia (laptop) →
gaming/branding/terranix/edge layers. Port each from
`archive/full-fleet-reference`, keeping the buildability rules above.
