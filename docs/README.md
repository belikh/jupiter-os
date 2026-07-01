# Jupiter OS Documentation

Full reference documentation for the **jupiter-os** monorepo — a
declarative, ZFS-backed NixOS fleet plus the edge devices and cloud
infrastructure around it. For a quick start (build/deploy commands), see the
root [`README.md`](../README.md). For instructions specific to AI coding
agents working in this repo, see [`CLAUDE.md`](../CLAUDE.md).

## Contents

1. **[Architecture](01-architecture.md)** — repo layout, the `mkHost` pattern, the `jupiter.*` module namespace, base-layer design (`common.nix` vs `common-stateful.nix`), CI overview.
2. **[Hosts](02-hosts.md)** — per-host reference: role, network identity, storage, boot path, imported modules, for `ganymede`, `europa`, `metis`/`adrastea`/`amalthea`/`thebe`, `callisto`, `himalia`.
3. **[Software Inventory](03-software-inventory.md)** — every package and service, organized by fleet-wide baseline, machine class, and individual host.
4. **[Modules Reference](04-modules-reference.md)** — every `modules/*.nix` file: its `jupiter.*` options, defaults, and which hosts enable it. The option-by-option detail is generated into [module-options.md](module-options.md) via `make docs-modules` (nixos-render-docs), so it can't drift from the code.
5. **[Networking & DNS](05-networking.md)** — VLANs/subnets, the unbound + dnscrypt-proxy resolver chain, headscale mesh, Cloudflare Tunnel ingress, firewall ports.
6. **[Storage & Backups](06-storage-and-backups.md)** — ZFS pools/datasets per host, sanoid snapshot policy, restic offsite backups, iSCSI/NFS/SMB.
7. **[Secrets Management](07-secrets-management.md)** — sops-nix + Age key model, what's in `secrets/secrets.yaml`, bootstrapping a new host's key.
8. **[Edge Devices](08-edge-devices.md)** — Linksys MX4300 mesh APs (custom OpenWrt) and Wyze cameras at the parents' house site.
9. **[Operations](09-operations.md)** — `Makefile` command reference, `deploy-rs`, bootstrapping a new host, QEMU testing, CI pipeline.
10. **[Terraform (terranix)](10-terraform.md)** — the UniFi and Cloudflare stacks: resources, variables, render/apply flow.

## Where to start

- **"What does host X run?"** → [02-hosts.md](02-hosts.md), then [03-software-inventory.md](03-software-inventory.md) for the package-level detail.
- **"What does this `jupiter.foo.bar` option do?"** → [04-modules-reference.md](04-modules-reference.md) for the narrative, [module-options.md](module-options.md) for the exact type/default/description.
- **"How do I add a new host / rotate a secret / ship a config change?"** → [09-operations.md](09-operations.md) and [07-secrets-management.md](07-secrets-management.md).
- **"How does traffic get from the internet to a service?"** → [05-networking.md](05-networking.md).

## Conventions used in these docs

- File paths are relative to the repo root unless stated otherwise.
- Tables list **what is actually declared in this repo today** — where a
  comment in the source describes intent that isn't backed by a config yet
  (e.g. the Loki/DB stack referenced from `callisto`'s iSCSI LUNs), that's
  called out explicitly rather than presented as already running.
- "Enabled by" / "imported by" call out which host(s) currently opt into a
  given module or option — most `jupiter.*` toggles default to `false` and
  are off fleet-wide unless a host sets them.
