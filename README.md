# Jupiter OS

A declarative, ZFS-backed NixOS monorepo for the Jupiter infrastructure.

> **Full documentation:** see [`docs/`](docs/README.md) for architecture,
> a per-host reference, the complete software inventory for every machine,
> networking/storage/secrets details, and operational runbooks. This README
> stays focused on the quick-start commands.

## Topology
- **Lenovo Compute Node**: Bare-metal NixOS host running the Home Assistant VM (HAOS) and `n8n`.
- **Jupiter NAS**: ZFS storage array. The central backup and replication target for the fleet.
- **T460s Laptop**: Personal workstation.
- **Toshiba Dashboards**: 4x Wayland Kiosk touchscreen nodes.
- **Elitedesk 800 G4**: Diskless compute node (netboots from PXE).

## Secrets
Secrets are managed with `sops-nix` and `Age`. The master key is derived from the primary admin SSH key (`id_ed25519`).
All secrets live encrypted in `secrets/secrets.yaml`.

## Deployment

Build and test configurations locally using the `Makefile`:
```bash
make build-all          # build every host closure + mx4300 firmware
make test-lenovo        # build & boot a host in a QEMU VM
make check              # nix flake check (evaluates all hosts + deploy checks)
make fmt                # format Nix sources (nixfmt-rfc-style)
```

Deploy remotely using `deploy-rs` (all five hosts are registered as nodes):
```bash
deploy .#lenovo
```

### Bootstrapping a new host
1. Generate the host's age key and add its public key to `.sops.yaml`, then
   re-encrypt: `sops updatekeys secrets/secrets.yaml`.
2. Add the host to `hosts/`, then to `nixosConfigurations` and `deploy.nodes`
   in `flake.nix`.
3. Partition + install with disko (for hosts with local disks), e.g. via
   `nixos-anywhere --flake .#<host> root@<ip>`. `elitedesk` is diskless and
   netboots from the PXE server on `lenovo`.

### Network / DNS (Terraform via terranix)
The UniFi and Cloudflare configs are authored in Nix under `terraform/` and
applied through the Makefile (secrets injected from `secrets.yaml` as `TF_VAR_*`):
```bash
make tf-plan-unifi      # review changes
make tf-apply-unifi
make tf-plan-cloudflare
make tf-apply-cloudflare
```
> Note: `tf-apply-cloudflare` needs a `cloudflare_api_token` entry in
> `secrets/secrets.yaml` (add it with `sops secrets/secrets.yaml`).

### Edge firmware (Linksys MX4300 APs)
```bash
make build-mx4300       # renders secret templates via sops, builds OpenWrt image
```

## CI
`.github/workflows/ci.yml` runs formatting + `nix flake check` and builds every
host closure on each push/PR.
