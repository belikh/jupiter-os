# sops-nix and agenix in detail

## Decryption timing (why the design works)

Both tools decrypt during **activation**, after the secret-management service
starts. sops-nix installs secrets under `/run/secrets.d/<generation>` and
symlinks `/run/secrets` to the newest generation (atomic swap). Encrypted
files can sit in the Nix store and in git; `nix build`, `nix flake check`, and
CI all run without any key. Using a secret at evaluation time is unsupported
by design — the correct workarounds are `sops.templates` (literal content
substitution at activation) or passing the path to the consumer.

## sops-nix

Import `sops-nix.nixosModules.sops` from the flake (or `<sops-nix/modules/sops>`).

Global options:

| Option | Meaning |
|---|---|
| `sops.defaultSopsFile` | default encrypted file |
| `sops.defaultSopsFormat` | `yaml` (default), `json`, `binary`, `dotenv`, `ini` |
| `sops.age.keyFile` | age private key at a path outside the store (e.g. `/var/lib/sops-nix/key.txt`) |
| `sops.age.generateKey` | create a key on first activation if absent |
| `sops.age.sshKeyPaths` | derive age keys from SSH host keys (defaults to ed25519 host keys) |
| `sops.gnupg.home` / `sshKeyPaths` | GnuPG alternatives |
| `sops.validateSopsFiles` | check encrypted files at evaluation (default `true`; file must be in the store) |
| `sops.keepGenerations` | installed secret generations kept (default 1; `0` disables pruning) |
| `sops.useSystemdActivation` | run secret installation as an early systemd unit |

Per-secret options (`sops.secrets.<name>`):

| Option | Meaning |
|---|---|
| `key` | key inside the sops file (defaults to the attribute name; `""` = whole file) |
| `path` | runtime path (default `/run/secrets/<name>`; `/run/secrets-for-users/<name>` with `neededForUsers`) |
| `owner`, `uid`, `group`, `gid`, `mode` | file ownership and permissions (mode default `0400`) |
| `format`, `sopsFile` | per-secret overrides |
| `neededForUsers` | decrypt before user creation (for `hashedPasswordFile`); cannot set owner/group |
| `restartUnits`, `reloadUnits` | restart/reload units when the secret changes |
| `sopsFileHash` | read-only hash for `restartTriggers` |

Templates — activation-time text with secrets interpolated:

```nix
sops.templates."app.env" = {
  content = ''
    DB_PASSWORD=${config.sops.placeholder."db/password"}
  '';
  owner = "myapp";
};
# consume config.sops.templates."app.env".path
```

`.sops.yaml` (repository root):

```yaml
keys:
  - &admin age1…
  - &host-europa age1…
creation_rules:
  - path_regex: secrets/[^/]+\.yaml$
    key_groups:
      - age: [ *admin, *host-europa ]
```

A stray `-` before a second key type switches sops to Shamir secret sharing
(all keys required) and breaks sops-nix — one flat `age:` list per group.

Key operations:

```bash
ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub      # host key → age recipient
ssh-keyscan host | ssh-to-age                        # remote variant
sops updatekeys secrets.yaml                         # re-encrypt for the current .sops.yaml rules
sops rotate --in-place secrets.yaml                  # new data key
# After removing a compromised recipient:
#   remove from .sops.yaml → sops updatekeys → sops rotate → then rotate the credential itself
```

## agenix

```nix
age.secrets."db-password" = {
  file = ./secrets/db-password.age;   # required
  owner = "postgres";
  mode = "0400";
  # path defaults to /run/agenix/<name>; symlink defaults to true
};
age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];  # strings, not paths
```

- One secret per file; edit with `agenix -e secrets/db-password.age`, rekey
  with `agenix -r`.
- Identity paths must be **strings** — Nix paths would copy private keys into
  the store.
- `symlink = false` for programs that refuse symlinked config (some Java
  services).
- Age itself does not authenticate ciphertexts (no MAC) and is not
  post-quantum safe — the README states this threat model. sops' age backend
  adds authenticated encryption.

## Declarative passwords

- `users.mutableUsers = true` (default): password options apply at user
  creation only; `passwd` can change them afterwards.
- `users.mutableUsers = false`: `/etc/passwd`/`group` are regenerated each
  activation; changed passwords are reset, and `useradd`/`usermod` are
  unavailable.
- Use `hashedPasswordFile`, fed from the secret manager, for anything real.
  Plaintext `password`/`initialPassword` end up world-readable in the Nix
  store — never put a real secret there.
- Generate hashes with `mkpasswd -m yescrypt` (libxcrypt `$y$…`) or `mkpasswd -s`;
  `openssl passwd -6` produces sha512crypt (`$6$`), which is structurally
  accepted but weaker.
- Root is `users.users.root.hashedPassword`/`hashedPasswordFile`
  (`security.initialRootPassword` is renamed away).
- With sops-nix, the canonical pair is
  `neededForUsers = true` plus `hashedPasswordFile =
  config.sops.secrets.<name>.path`.

## Detection recipes

- **Store leak:** grep config for secret-path interpolation and inspect
  `nix log`/`nix-store -q --references` for suspicious text; the design says
  this should be impossible — find the mechanism that defeated it.
- **Stale secret:** compare `stat -c %Y /run/secrets/<name>` with
  `systemctl show -p ActiveEnterTimestamp <unit>`; if the unit predates the
  file, add `restartUnits`.
- **Ordering failure:** unit journal shows `ENOENT`/`Permission denied` on the
  secret path; check `After=`/`Requires=` against the secret unit, especially
  for Home Manager user services (add `After = [ "sops-nix.service" ];`).
- **Wrong recipient:** run `sops -d <file>` on the host — it succeeds only if
  that host's key is a recipient.

## Sources

- sops-nix README (options, templates, placeholders, rotation): https://github.com/Mic92/sops-nix (accessed 2026-09-30)
- agenix README (options, rules, rekey): https://github.com/ryantm/agenix (accessed 2026-09-30)
- NixOS manual, user management: https://nixos.org/manual/nixos/stable/#sec-user-management (accessed 2026-09-30)
- nixpkgs `users-groups.nix` (option precedence): https://github.com/NixOS/nixpkgs (accessed 2026-09-30)
