# CLAUDE.md

Context for AI agents working in **jupiter-os** — a declarative, ZFS-backed
NixOS monorepo for the Jupiter home/lab infrastructure, currently being
**rebuilt from scratch one machine at a time**. The previous full-fleet tree
lives on the `master` branch and serves as the design reference; it was never
buildable end-to-end (see README.md for why). Do not copy code from it
wholesale — port pieces only when the machine that needs them is brought up.

## Current state

Single registered host: `amalthea`, a TCx Wave dashboard kiosk and the
bootstrap machine for the whole fleet. Everything must keep building from
cache.nixos.org with `nix flake check`.

## Layout

- `flake.nix` — entry point. Inputs are deliberately minimal (nixpkgs, disko,
  impermanence, sops-nix). `mkHost` injects flake modules via a lexical
  closure — avoid `specialArgs`. Every host in `nixosConfigurations` is also
  a flake check.
- `hosts/<name>/` — per-host config (`configuration.nix`). Hosts are named
  after Jupiter's moons.
- `modules/` — reusable NixOS modules behind a `jupiter.*` options namespace,
  organized into category subdirs (`core/`, `desktop/`, `storage/`,
  `services/`). `common.nix` at the `modules/` root is the base layer.
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

## Common commands

```bash
make check              # nix flake check (builds every registered host)
make build-all          # build every host closure
make test-<host>        # build & boot a host in a QEMU VM
make boot-smoke-<host>  # headless CI-style boot test
make fmt                # format all Nix (nixfmt-rfc-style); fmt-check to verify
```

## Roadmap (bring-up order)

amalthea (done, this tree) → the other 3 kiosks (metis/adrastea/thebe) →
ganymede (resolver/services) → europa (NAS + backup wiring) → callisto
(diskless PXE) → himalia (laptop) → gaming/branding/terranix/edge layers.
Port each from `master`, keeping the buildability rules above.
