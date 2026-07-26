#!/usr/bin/env bash
# Stands in for `nix flake update`: deterministically bumps the nixpkgs
# input in flake.lock and prints the same shape of diff Nix would print.
set -euo pipefail
cd "$(dirname "$0")/.."

NEW_REV="9ew0000000000000000000000000000000000000"
NEW_HASH="sha256-NEWHASHNEWHASHNEWHASHNEWHASHNEWHASHNEWHASHNEW="
NEW_MOD=1750000000

OLD_REV=$(grep -o '"rev": "[a-z0-9]*"' flake.lock | head -1 | cut -d'"' -f4)

sed -i "s/$OLD_REV/$NEW_REV/" flake.lock
sed -i "s/sha256-OLDHASH[A-Za-z0-9+\/=]*/$NEW_HASH/" flake.lock
sed -i "s/\"lastModified\": [0-9]*/\"lastModified\": $NEW_MOD/" flake.lock

echo "• Updated input 'nixpkgs':"
echo "    'github:NixOS/nixpkgs/$OLD_REV'"
echo "  -> 'github:NixOS/nixpkgs/$NEW_REV'"
