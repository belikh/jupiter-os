# Operations

## 1. Command reference (`Makefile`)

| Command | What it does |
|---|---|
| `make build-all` | Builds every host's `system.build.toplevel` plus the MX4300 firmware, in sequence. Good smoke test that the whole flake still evaluates and builds. |
| `make test-<host>` | `nixos-rebuild build-vm --flake .#<host>`, then launches it: `./result/bin/run-<host>-vm -m 2048 -smp 2`. Works for any host (`test-lenovo`, `test-nas`, `test-dashboards`, `test-elitedesk`, `test-t460s`) via the `test-%` pattern rule. Each host's `virtualisation.vmVariant` (set in `modules/common.nix`) swaps in a BIOS/MBR GRUB config and a passwordless `io`/`root` login for the VM only. |
| `make check` | `nix flake check` — evaluates every host plus deploy-rs checks. |
| `make fmt` | `nix fmt` (`nixfmt-rfc-style`) — formats all Nix sources in place. |
| `make fmt-check` | Same formatter, `--check` mode, no writes — what CI runs. |
| `make update` | `nix flake update` — bumps all flake input locks. |
| `make build-mx4300` | Renders edge-device secret templates, builds the OpenWrt firmware, deletes the rendered plaintext. See [08-edge-devices.md](08-edge-devices.md#3-rendering-and-building-edge-device-artifacts). |
| `make tf-plan-unifi` / `tf-apply-unifi` | Render + plan/apply the UniFi terranix stack. See [10-terraform.md](10-terraform.md). |
| `make tf-plan-cloudflare` / `tf-apply-cloudflare` | Same, for the Cloudflare stack. Needs `cloudflare_api_token` added to secrets first (not present by default — see [07-secrets-management.md](07-secrets-management.md)). |

## 2. Remote deployment (`deploy-rs`)

All five NixOS hosts are registered as `deploy.nodes` in `flake.nix`, each
deploying as `root` to a profile built from
`deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.<host>`:

```bash
nix develop                  # picks up deploy-rs from shell.nix
deploy .#lenovo
deploy .#nas
deploy .#elitedesk
deploy .#t460s
deploy .#dashboards
```

`deploy-rs` connects over SSH to the hostname matching the host's
`networking.hostName`, activates the new generation, and rolls back
automatically if the new generation fails its health checks. This is the
intended path for ongoing changes to already-installed hosts.
`checks = deploy-rs.lib.<system>.deployChecks self.deploy` (in `flake.nix`)
gives `nix flake check` visibility into whether the deploy graph itself is
well-formed.

## 3. Bootstrapping a brand-new host

(Mirrors `README.md` §"Bootstrapping a new host"; cross-referenced from
[07-secrets-management.md](07-secrets-management.md#4-bootstrapping-a-new-hosts-key-from-readmemd).)

1. Generate the host's Age key, add it to `.sops.yaml`, then
   `sops updatekeys secrets/secrets.yaml`.
2. Add `hosts/<name>/configuration.nix` — for a local-disk host, set
   `jupiter.storage.profile` + `jupiter.storage.disk` (or write a bespoke
   `disko.nix` like `nas` if the layout is unusual) — then register it in both
   `nixosConfigurations` and `deploy.nodes` in `flake.nix`.
3. Partition + install:
   - Hosts with local disks: `nixos-anywhere --flake .#<host> root@<ip>` (disko handles partitioning — **confirm the real disk's by-id path first**; `jupiter.storage.disk` defaults to a `REPLACE-ME` placeholder that fails an assertion until you set it).
   - Diskless hosts: wire them into the PXE server instead, the way `elitedesk` is wired into `lenovo`'s `jupiter.pxe` in `flake.nix` (see [01-architecture.md §3](01-architecture.md#3-the-mkhost-pattern-flakenix)).

## 4. Testing changes before deploying

`make test-<host>` is the fast local feedback loop: it builds the host's VM
variant and boots it under QEMU, with a passwordless login so you can poke
around interactively. This is a build of the *actual* host config (not a
separate "dev" config) — `virtualisation.vmVariant` in `modules/common.nix`
only patches the bootloader/disk-size/password bits needed to run under
QEMU, everything else is identical to what would ship to real hardware.

For a true pre-deploy check without booting anything:

```bash
make build-all     # builds every host's toplevel closure
make check          # nix flake check (full evaluation + deploy-rs checks)
make fmt-check      # formatting, no writes
```

These three are exactly what CI runs (see below), so passing them locally is
a strong signal a push will pass CI too.

## 5. CI pipeline (`.github/workflows/ci.yml`)

Triggers: push to `master`, any PR, manual `workflow_dispatch`. Concurrency
is grouped per workflow+ref with `cancel-in-progress: true`, so superseding
pushes cancel stale runs.

| Job | Steps |
|---|---|
| `check` | `nixfmt-rfc-style --check .`, then `nix flake check --no-build` |
| `build` (matrix: `lenovo`, `t460s`, `nas`, `dashboards`, `elitedesk`) | `nix build .#nixosConfigurations.<host>.config.system.build.toplevel` |

Both jobs use `DeterminateSystems/nix-installer-action` and
`magic-nix-cache-action`. Crucially, **no Age/sops decryption key is needed
in CI** — secrets are read at activation time on the real host, not at
build/eval time, so `nix flake check` and `nix build` succeed without one.
(`make build-mx4300` and `make tf-*` are the exceptions — see
[07-secrets-management.md §6](07-secrets-management.md#6-gotchas).)

## 6. Things to double check before relying on a fresh checkout

- `lenovo` and `dashboards` set `jupiter.storage.disk` to a placeholder
  (`REPLACE-ME-...`), and `nas`'s bespoke `disko.nix` does the same. The
  storage module asserts against the placeholder so a stray `disko` run fails
  loudly instead of wiping a real disk. Replace with the real by-id path before
  installing.
- `jupiter.nas.bond.enable` is `false` — the matching LACP config must exist
  on the UniFi switch before flipping it on, or the NAS drops off the
  network (see [04-modules-reference.md](04-modules-reference.md#modulesnetworknas-bondnix)).
- `cloudflare_api_token` is not yet in `secrets/secrets.yaml` — `tf-apply-cloudflare` will fail until it's added.
