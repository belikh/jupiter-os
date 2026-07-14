# CLAUDE.md

Context for AI agents working in **jupiter-os** — a declarative, ZFS-backed
NixOS monorepo for the Jupiter home/lab infrastructure, currently being
**rebuilt from scratch one machine at a time**. The previous full-fleet tree
lives on the `master` branch and serves as the design reference; it was never
buildable end-to-end (see README.md for why). Do not copy code from it
wholesale — port pieces only when the machine that needs them is brought up.

## Current state

Registered hosts: the 4 TCx Wave dashboard kiosks — `amalthea`
(jupiter-bedroom, the bootstrap machine and canonical template), `metis`
(kitchen), `adrastea` (office), `thebe` (robbie-room) — plus `europa`
(HPE MicroServer Gen10, the ZFS NAS + data hub) and `pallene` (ephemeral
BinaryLane build-server ISO host, phase2 only). The kiosk siblings are clones
of amalthea differing only in hostName/hostId/dashboard URL/disk.

**europa bring-up:** Stage 1 (untuned NAS) is **done and running** at
`10.1.1.2`. Stage 3 runtime prerequisites (tunnel UUID, R2 creds, attic public
key, build-server tokens) are all real and committed. **Next step = Stage 4**:
build the `btver2`-tuned closure via `make rebuild-world`. See
`docs/europa-bringup-stages.md` (on `feat/europa-phase2-tuned-closure`) for the
full runbook — start a new session there.

Everything must keep building from cache.nixos.org with `nix flake check`
(note: on the phase2 branch, europa's `btver2` closure won't substitute — use
`make check`, which runs eval-only; raw `nix flake check` would try to compile
it until Stage 4 populates the attic cache).

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

amalthea (done) → the other 3 kiosks (metis/adrastea/thebe — done) →
europa (Stage 1 NAS done; **next: Stage 4 `make rebuild-world` for the btver2
tuned closure** — see `docs/europa-bringup-stages.md`) → ganymede
(resolver/services) → callisto (diskless PXE) → himalia (laptop) →
gaming/branding/terranix/edge layers. Port each from `master`, keeping the
buildability rules above.
