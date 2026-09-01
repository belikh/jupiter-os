#!/usr/bin/env bash
# Helper for opencode/agents on callisto to manage sops secrets safely.
# Per CLAUDE.md: NEVER decrypt secrets to disk or echo them into chat.
# This script automates common secure workflows (editing, adding keys, extracting a single key).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SECRETS_FILE="$REPO_ROOT/secrets/secrets.yaml"
SOPS_CONFIG="$REPO_ROOT/.sops.yaml"

if command -v sops &>/dev/null; then
  SOPS="sops"
else
  SOPS="nix run nixpkgs#sops --"
fi

cmd="${1:-help}"

case "$cmd" in
  edit)
    echo "Opening secrets.yaml in sops editor..."
    cd "$REPO_ROOT"
    $SOPS "$SECRETS_FILE"
    ;;
  extract)
    key="${2:-}"
    if [ -z "$key" ]; then
      echo "Usage: $0 extract <secret-name>" >&2
      exit 1
    fi
    echo "Extracting secret '$key' (piping directly without echoing plaintext to stdout)..." >&2
    $SOPS --extract "[\"$key\"]" "$SECRETS_FILE" | tr -d '\n'
    echo "" >&2
    ;;
  set)
    key="${2:-}"
    if [ -z "$key" ]; then
      echo "Usage: $0 set <secret-name>" >&2
      echo "Enter the secret value when prompted (reads from stdin)." >&2
      exit 1
    fi
    echo "Setting secret '$key' via stdin..."
    $SOPS set --value-stdin "$SECRETS_FILE" "[\"$key\"]"
    echo "Secret '$key' updated successfully."
    ;;
  updatekeys)
    echo "Updating sops encryption keys from .sops.yaml recipients..."
    cd "$REPO_ROOT"
    $SOPS updatekeys -y "$SECRETS_FILE"
    echo "Keys updated successfully."
    ;;
  info)
    echo "=== SOPS Environment Info ==="
    echo "Repo root: $REPO_ROOT"
    echo "Secrets file: $SECRETS_FILE"
    echo "SOPS config: $SOPS_CONFIG"
    if [ -n "${SOPS_AGE_KEY_FILE:-}" ]; then
      echo "SOPS_AGE_KEY_FILE: $SOPS_AGE_KEY_FILE"
    elif [ -f "$HOME/.config/sops/age/keys.txt" ]; then
      echo "Age key found at: $HOME/.config/sops/age/keys.txt"
    else
      echo "WARNING: No age key found in default location or SOPS_AGE_KEY_FILE."
    fi
    ;;
  *)
    echo "Usage: $0 {edit|extract <key>|set <key>|updatekeys|info}"
    echo ""
    echo "Commands:"
    echo "  edit          - Open encrypted secrets.yaml in editor ($EDITOR)"
    echo "  extract <key> - Extract a single secret value safely"
    echo "  set <key>     - Set a secret value from stdin securely"
    echo "  updatekeys    - Re-encrypt secrets.yaml with any new age keys from .sops.yaml"
    echo "  info          - Check sops configuration and age key presence"
    exit 1
    ;;
esac
