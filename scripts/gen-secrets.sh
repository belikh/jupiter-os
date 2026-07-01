#!/usr/bin/env bash
#
# Generate strong, random machine-to-machine credentials straight into the sops
# store, so no service password is ever chosen by hand. Idempotent: only fills
# in keys that are missing, so it's safe to re-run after adding a new
# inter-service secret.
#
# Scope: service-to-service credentials only. It deliberately does NOT touch
#   - io_password    (a human login password — set that yourself)
#   - restic_env, cloudflare_*, unifi_password, WYZE_*, PARENTS_*,
#     binarylane_api_token, r2_* (external accounts whose values come from
#     the provider, not us)
#   - attic_push_token (a client JWT that has to be minted with `atticadm
#     make-token` against atticd's OWN running instance — see
#     docs/roadmap.md; can't be generated ahead of that server existing)
#
# Requires the age key (same as editing secrets) + sops, openssl, ssh-keygen, jq.
# Run from anywhere: `make gen-secrets`.
set -euo pipefail
cd "$(dirname "$0")/.."

SOPS_FILE="secrets/secrets.yaml"
PUBKEY_FILE="secrets/syncoid_ed25519.pub"

# Service passwords: impossible 256-bit hex. Add new inter-service secrets here
# and they'll be generated on the next run.
PASSWORD_KEYS=(
  pg_homeassistant_password
  pg_n8n_password
  mqtt_homeassistant
  mqtt_ha_linux_agent
  restic_password
)

have() { sops -d "$SOPS_FILE" 2>/dev/null | grep -qE "^${1}:"; }

set_value() { sops --set "[\"$1\"] $2" "$SOPS_FILE"; }

echo "==> Generating service passwords (impossible, random; missing keys only)"
for key in "${PASSWORD_KEYS[@]}"; do
  if have "$key"; then
    echo "    $key: present, skipping"
  else
    set_value "$key" "\"$(openssl rand -hex 32)\""
    echo "    $key: generated"
  fi
done

echo "==> syncoid replication SSH key (NAS pulls server state)"
if have syncoid_ssh_key; then
  echo "    syncoid_ssh_key: present, skipping"
else
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  ssh-keygen -t ed25519 -N "" -C "europa-syncoid" -f "$tmp/key" >/dev/null
  set_value syncoid_ssh_key "$(jq -Rs . < "$tmp/key")"
  cp "$tmp/key.pub" "$PUBKEY_FILE"
  echo "    syncoid_ssh_key: generated (private -> sops)"
  echo "    $PUBKEY_FILE: written (public key — commit it, it's not secret)"
fi

echo "==> attic binary cache server token secret (RS256 JWT signing key)"
if have attic_server_token_secret; then
  echo "    attic_server_token_secret: present, skipping"
else
  rsa_b64="$(openssl genrsa -traditional 4096 2>/dev/null | base64 -w0)"
  set_value attic_server_token_secret "\"ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=$rsa_b64\""
  echo "    attic_server_token_secret: generated"
fi

echo
echo "Done. Commit the updated $SOPS_FILE and $PUBKEY_FILE."
echo "Note: HA is a HAOS VM, so paste its generated pg_homeassistant_password /"
echo "mqtt_homeassistant into Home Assistant's UI (decrypt with: sops -d $SOPS_FILE)."
