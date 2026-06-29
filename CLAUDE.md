# CLAUDE.md

Context for AI agents working in **jupiter-os** — a declarative, ZFS-backed NixOS
monorepo for the Jupiter home/lab infrastructure.

## Layout

- `flake.nix` — entry point. Defines `nixosConfigurations`, `deploy.nodes`
  (deploy-rs), `packages` (OpenWrt firmware + terranix configs), `checks`,
  `formatter`, and the dev shell (`shell.nix`).
- `hosts/<name>/` — per-host config (`configuration.nix`; `disko.nix` only for
  bespoke layouts like `nas` — most hosts use `jupiter.storage.profile`). Active
  hosts: `lenovo`, `nas`, `dashboards`, `elitedesk` (diskless/PXE netboot),
  `t460s` (laptop). `hosts/desktop/` and `hosts/parents-desktop/` are scaffolds
  for future roaming workstations (not yet registered in `flake.nix`).
  `hosts/parents-house/` holds edge device templates (Linksys MX4300 APs, Wyze
  cams) — not NixOS hosts.
- `modules/` — reusable NixOS modules, exposed behind a `jupiter.*` options
  namespace (feature toggles), e.g. `jupiter.core.impermanence.enable`,
  `jupiter.desktop`, `jupiter.storage.profile`, `jupiter.services.*`,
  `jupiter.pxe`. Organized into category subdirs: `core/`, `desktop/`,
  `gaming/`, `storage/`, `network/`, `services/`. `common.nix` /
  `common-stateful.nix` are the base layers at the `modules/` root.
- `terraform/<stack>/default.nix` — terranix (Nix-authored HCL) for `unifi` and
  `cloudflare`. Rendered to `config.tf.json` and applied via the Makefile.
- `secrets/secrets.yaml` — sops-nix + age. Recipients (one age key per host plus
  the admin key) are listed in `.sops.yaml`.
- `packages/` — custom builds (OpenWrt MX4300 firmware, Share Tech Mono font).

## Conventions

- New cross-host functionality goes in a `modules/<category>/` file gated by a
  `jupiter.*` option; hosts opt in via toggles rather than inlining config.
- **Module style:** prefer explicit `lib.mkOption` / `lib.mkIf` / `lib.types`
  over `with lib;`; argument order `{ config, lib, pkgs, ... }`; structure each
  module as `options.jupiter.<…> = { … }` then `config = lib.mkIf cfg.enable { … }`
  with `cfg = config.jupiter.<…>` bound in a `let`. (Some older modules still
  use `with lib;` — convert opportunistically; new modules follow this.)
- `mkHost` in `flake.nix` injects flake modules (sops, impermanence, disko,
  home-manager, jovian, chaotic) via a lexical closure — avoid `specialArgs`.
- The portable user environment for `io` (dotfiles, niri config) lives in
  `modules/home/` and is opt-in via `jupiter.home.enable`; data dirs roam via
  Syncthing rather than home-manager.
- **Central backup is automatic — don't wire it per host.** A host with local
  persistent state replicates to the NAS (the data hub) and thence offsite. The
  `stateful` storage profile defaults `jupiter.backup.enable` on with
  `datasets = [ "rpool/var" ]`; override `jupiter.backup` for anything unusual.
  The NAS derives its syncoid sources from every host's `jupiter.backup` in
  `flake.nix` (`backupHubModule`), and `modules/storage/backup.nix` auto-
  authorizes the NAS pull key on each source — so **new state-holding hosts are
  backed up with no edit to the NAS**. (Diskless hosts whose data already lives
  on NAS iSCSI leave it off; appliances/laptops roam via Syncthing instead.)
- The PXE server on `lenovo` is wired directly to `elitedesk`'s netboot build
  products in `flake.nix`; keep that closure linkage intact.
- Network facts (VLANs/subnets/resolver/DNS records) live once in `lib/site.nix`
  as plain data; both the NixOS resolver config (`hosts/lenovo` → `jupiter.dns`)
  and the terranix UniFi stack (`terraform/unifi`) `import` it, so CIDRs are
  never re-stated in two places.

- **Service-to-service passwords are generated, never hand-set.** Any credential
  two machines/services use to talk to each other is a random, impossible value
  produced by `make gen-secrets` (`scripts/gen-secrets.sh`) straight into sops —
  add the key name to that script's list, never ask a human to choose it. Only
  human logins (`io_password`) and external-account creds (B2, Cloudflare, UniFi,
  edge devices) are set by hand.

## Common commands

```bash
make build-all          # build every host closure + mx4300 firmware
make test-<host>        # build & boot a host in a QEMU VM
make check              # nix flake check
make fmt                # format all Nix (nixfmt-rfc-style); fmt-check to verify
make build-mx4300       # build OpenWrt firmware (injects secrets via sops)
make tf-plan-unifi      # render + plan/apply terranix stacks (unifi|cloudflare)
make tf-apply-unifi
deploy .#<host>         # remote deploy via deploy-rs
```

## Gotchas

- sops secrets are read at **activation**, not build time — `nix build` and CI
  work without the age key. `make build-mx4300` and `make tf-*` DO need it.
- `terraform/cloudflare` expects a `cloudflare_api_token` secret; only
  `cloudflare_cert` currently exists in `secrets.yaml` — add the token before
  running `tf-apply-cloudflare`.
- Don't commit `result*`, `*.qcow2`, rendered `config.tf.json`, or decrypted edge
  configs — all are gitignored.
