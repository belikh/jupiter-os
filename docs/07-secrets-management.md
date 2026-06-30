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
| `ganymede` | `age1p8c8ylcp...` | Host key |
| `europa` | `age1glcaw46r...` | Host key |
| `himalia` | `age1mz3axkge...` | Host key |
| `callisto` | `age1ywucpcl3...` | Host key |
| `metis`, `adrastea`, `amalthea`, `thebe` | (placeholder keys) | Dashboard kiosk host keys — not yet installed, so these are throwaway placeholders, not derived from any real SSH host key; replace each at install time (§4) |

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
| `restic_password` | `modules/services/backups.nix` (`europa`) | Local encryption key for restic backups |
| `restic_env` | `modules/services/backups.nix` (`europa`) | S3 credentials (`AWS_ACCESS_KEY_ID` etc.) for the Backblaze B2 repository |
| `cloudflare_cert` | `modules/network/cloudflared.nix` (`ganymede`) | Tunnel credentials file |
| `mqtt_homeassistant`, `mqtt_dashboard` | `modules/services/mqtt.nix` (`ganymede`), dashboard kiosks | MQTT broker passwords |

### Generated — never hand-set (`make gen-secrets`)

Service-to-service credentials are **random and machine-generated**, not chosen
by a human. `scripts/gen-secrets.sh` (via `make gen-secrets`) fills in any
missing key with an impossible value (256-bit hex, or an ed25519 keypair) and
writes it straight into the sops file — idempotent, so re-running only adds
what's missing. The syncoid public key is written to
`secrets/syncoid_ed25519.pub` (committed; not secret) and read by `lib/site.nix`.

| Key | Used by |
|---|---|
| `pg_homeassistant_password` | `callisto` Postgres `homeassistant` role (also pasted into HA's `db_url`) |
| `pg_n8n_password` | `callisto` Postgres `n8n` role **and** ganymede's n8n (decrypt on both) |
| `mqtt_homeassistant`, `mqtt_dashboard` | MQTT broker + clients |
| `restic_password` | restic backup encryption key |
| `syncoid_ssh_key` | europa's syncoid pull key (private → sops; public → committed `.pub`) |

### External — you provide (from the provider/account)

| Key | Needed for |
|---|---|
| `restic_env` | Backblaze B2 S3 credentials |
| `cloudflare_cert`, `cloudflare_api_token` | Cloudflare tunnel + API |
| `unifi_password` | terranix UniFi stack |
| `io_password` | the human login password for user `io` |
| `PARENTS_MESH_SECRET`, `PARENTS_WIFI_SECRET`, `WYZE_PASSWORD` | edge device templates |

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
4. Partition + install with disko (for hosts with local disks), e.g. via `nixos-anywhere --flake .#<host> root@<ip>`. (`callisto` is the exception — diskless, netboots from `ganymede`'s PXE server instead.)

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
