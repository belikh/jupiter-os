# CLAUDE.md

Context for AI agents working in **jupiter-os** — a declarative, ZFS-backed NixOS
monorepo for the Jupiter home/lab infrastructure.

## Layout

- `flake.nix` — entry point. Defines `nixosConfigurations`, `deploy.nodes`
  (deploy-rs), `packages` (OpenWrt firmware + terranix configs), `checks`,
  `formatter`, and the dev shell (`shell.nix`).
- `hosts/<name>/` — per-host config (`configuration.nix`, `disko.nix` where the
  host has local disks). Hosts: `lenovo`, `nas`, `dashboards`, `elitedesk`
  (diskless/PXE netboot), `t460s` (laptop). `hosts/parents-house/` holds edge
  device templates (Linksys MX4300 APs, Wyze cams) — not NixOS hosts.
- `modules/` — reusable NixOS modules, exposed behind a `jupiter.*` options
  namespace (feature toggles), e.g. `jupiter.core.impermanence.enable`,
  `jupiter.desktop`, `jupiter.storage.zfs`, `jupiter.services.*`, `jupiter.pxe`.
- `terraform/<stack>/default.nix` — terranix (Nix-authored HCL) for `unifi` and
  `cloudflare`. Rendered to `config.tf.json` and applied via the Makefile.
- `secrets/secrets.yaml` — sops-nix + age. Recipients (one age key per host plus
  the admin key) are listed in `.sops.yaml`.
- `packages/` — custom builds (OpenWrt MX4300 firmware, Share Tech Mono font).

## Conventions

- New cross-host functionality goes in a `modules/` file gated by a
  `jupiter.*` option; hosts opt in via toggles rather than inlining config.
- `mkHost` in `flake.nix` injects flake modules (sops, impermanence, disko) via a
  lexical closure — avoid `specialArgs`.
- The PXE server on `lenovo` is wired directly to `elitedesk`'s netboot build
  products in `flake.nix`; keep that closure linkage intact.
- Network facts duplicated between `terraform/unifi` and `modules/services/dns.nix`
  (VLANs/subnets) must be kept in sync — see comments in those files.

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
