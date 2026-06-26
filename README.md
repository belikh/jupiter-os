# Jupiter OS

A declarative, ZFS-backed NixOS monorepo for the Jupiter infrastructure.

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
make build-all
make test-lenovo
```
Deploy remotely using `deploy-rs`:
```bash
deploy .#lenovo
```
