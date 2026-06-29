# Secrets Management

Secrets are managed with **sops-nix** + **Age**, encrypted at rest in
`secrets/secrets.yaml` and decrypted at **activation time** on each target
host — never at build time, and never committed in plaintext.

## 1. Key model

`.sops.yaml` lists one Age public key per recipient and a creation rule that
encrypts `secrets/secrets.yaml` to all of them:

| Recipient | Key (truncated) | Role |
|---|---|---|
| `admin_io` | `age17c04srm4e...` | Derived from the primary admin's SSH key (`id_ed25519`); lets a human decrypt/edit secrets from a workstation |
| `lenovo` | `age1p8c8ylcp...` | Host key |
| `nas` | `age1glcaw46r...` | Host key |
| `t460s` | `age1mz3axkge...` | Host key |
| `dashboards` | `age1t0wgluaf...` | Host key |
| `elitedesk` | `age1ywucpcl3...` | Host key |

Each NixOS host derives its Age decryption key from its own SSH host key
(`sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ]`, set in
`modules/common.nix`) — there's no separate Age keypair to provision per
host beyond what SSH already generates on first boot.

## 2. Secrets currently defined (`secrets/secrets.yaml`)

The file itself is fully encrypted (values, not just specific fields); only
the key *names* are visible without the Age private key:

| Key | Consumed by | Purpose |
|---|---|---|
| `io_password` | `modules/common.nix` (every host) | Hashed login password for user `io` |
| `restic_password` | `modules/services/backups.nix` (`lenovo`, `nas`) | Local encryption key for restic backups |
| `restic_env` | `modules/services/backups.nix` (`lenovo`, `nas`) | S3 credentials (`AWS_ACCESS_KEY_ID` etc.) for the Backblaze B2 repository |
| `cloudflare_cert` | `modules/network/cloudflared.nix` (`lenovo`) | Tunnel credentials file |

Referenced by the Makefile/edge-device templates but **not yet present** in
`secrets/secrets.yaml` (see `CLAUDE.md` gotchas and `Makefile` comments):

| Key | Needed for |
|---|---|
| `cloudflare_api_token` | `make tf-apply-cloudflare` (terranix Cloudflare stack) |
| `unifi_password` | `make tf-apply-unifi` / `tf-plan-unifi` (terranix UniFi stack) — referenced by the Makefile's `tf-run` macro |
| `PARENTS_MESH_SECRET`, `PARENTS_WIFI_SECRET` | MX4300 firmware template (`99-mesh-setup.sh.tmpl`) |
| `WYZE_PASSWORD` | Wyze cam config template (`wz_mini.conf.tmpl`) |

(`unifi_password` is consumed via `sops exec-env` exporting it as
`TF_VAR_unifi_password`; check `secrets/secrets.yaml`'s actual key list with
`sops` before assuming it's missing — the table above reflects what's
referenced in tracked files, not a guaranteed-current dump of the encrypted
file's keys.)

## 3. Editing secrets

```bash
sops secrets/secrets.yaml          # opens decrypted in $EDITOR, re-encrypts on save
```

This requires one of the Age private keys above to be available locally
(typically the admin key, derived from `id_ed25519`).

## 4. Bootstrapping a new host's key (from `README.md`)

1. Generate the host's Age key (commonly derived from its future SSH host key) and add the public key to `.sops.yaml`.
2. Re-encrypt the secrets file to include the new recipient:
   ```bash
   sops updatekeys secrets/secrets.yaml
   ```
3. Add the host under `hosts/`, then register it in `nixosConfigurations` and `deploy.nodes` in `flake.nix`.
4. Partition + install with disko (for hosts with local disks), e.g. via `nixos-anywhere --flake .#<host> root@<ip>`. (`elitedesk` is the exception — diskless, netboots from `lenovo`'s PXE server instead.)

## 5. Where secrets surface outside NixOS activation

Two non-NixOS consumers pull secrets at build/apply time via
`sops exec-env`, rather than relying on sops-nix's normal
activation-time decryption:

- **`make build-mx4300`** — runs `sops exec-env secrets/secrets.yaml 'envsubst < ... > ...'` to render `PARENTS_MESH_SECRET`/`PARENTS_WIFI_SECRET`/`WYZE_PASSWORD` into the OpenWrt/Wyze templates, builds the firmware, then immediately deletes the rendered plaintext files (also covered by `.gitignore`, as a second layer of protection against accidental commits).
- **`make tf-plan-unifi` / `tf-apply-unifi` / `tf-plan-cloudflare` / `tf-apply-cloudflare`** — runs `sops exec-env secrets/secrets.yaml 'TF_VAR_unifi_password=... TF_VAR_cloudflare_api_token=... terraform ...'`, injecting provider credentials as Terraform variables without ever writing them to disk.

See [09-operations.md](09-operations.md) and [10-terraform.md](10-terraform.md)
for the surrounding command flows.

## 6. Gotchas

- sops secrets are read at **activation**, not build time: `nix build` and CI work fine without any Age private key present; `make build-mx4300` and `make tf-*` *do* need one (they call `sops exec-env` directly).
- Don't commit `secrets/secrets.yaml` in any decrypted form, and don't commit the rendered edge-device configs (`99-mesh-setup.sh`, `wz_mini.conf`) — both are gitignored and the Makefile deletes them right after use.
