---
name: nixos-secrets
description: Manage NixOS secrets with sops-nix or agenix at activation time, plus declarative password hashes. Use when adding a secret, fixing decryption or ownership failures, or setting `hashedPasswordFile`.
---

# Secrets on NixOS

The invariant that shapes everything: **secrets are decrypted at activation,
never at evaluation or build time**. Encrypted files may live in the Nix store
(and in git); plaintext appears only under `/run/secrets*` on the running
machine. A build that needs a key is a bug.

## Working rule for agents

Never decrypt a secret wholesale into your context, a command line, or a
committed file. If a value is genuinely needed, extract that single key and
pipe it straight to its destination, then scrub any temporary copy. Refer to
secrets by their declared path (`config.sops.secrets.<name>.path`) so the
value never enters a transcript — context is not a security boundary.

## Workflow

1. **Pick the manager.** sops-nix for multi-secret files, `restartUnits`,
   templates, cloud KMS, authenticated encryption; agenix for minimal
   one-secret-per-file age-native setups that are easy to audit. Details and
   trade-offs in `references/sops-agenix.md`.
2. **Register the recipients.** Each host decrypts with its own key — usually
   its SSH host key converted with `ssh-to-age
   < /etc/ssh/ssh_host_ed25519_key.pub`. Add it to `.sops.yaml` creation rules
   (sops-nix) or the rules file (agenix). Verify the key is real for that host,
   not a placeholder. Done when an encrypted file lists the host's key.
3. **Add or edit the encrypted file.** `sops secrets.yaml` (opens an editor on
   the decrypted content) or `agenix -e secret.age`; adding a recipient later
   is `sops updatekeys secrets.yaml` / `agenix -r`. Done when the file is
   committed encrypted and the host key can decrypt it.
4. **Declare the secret in Nix** with the narrowest access:

   ```nix
   sops.secrets."db/password" = {
     owner = "postgres";
     mode = "0400";
     restartUnits = [ "postgresql.service" ];   # apply changes to a running unit
   };
   # consumers read the path at runtime, e.g.:
   systemd.services.myapp.serviceConfig.LoadCredential =
     "dbpass:${config.sops.secrets."db/password".path}";
   ```

   Done when the declaration names an owner, a mode, and (if a service consumes
   it) the restart/reload tie.
5. **For a login password**, route a hash through the secret: set
   `neededForUsers = true` and `users.users.<name>.hashedPasswordFile =
   config.sops.secrets.<name>.path;`. Never use plaintext `password`.
6. **Build without keys.** Run the ordinary evaluation/build with no key
   material present; it must succeed. Done when the build passes and no
   secret path is referenced outside `config`/runtime.
7. **Verify at activation.** After a switch: the secret exists at its path
   with the declared owner/mode, the consuming unit is active, and the
   journal shows no decryption errors. If the service was already running,
   confirm it actually restarted/reloaded.

## Pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| secret value in `/nix/store` or a build log | `builtins.readFile`/`toString` on a secret path, or interpolation into `environment.etc` | move consumption to runtime; never read secret paths at eval/build |
| activation fails: "no key could decrypt" | host key missing from recipients, or wrong key | `ssh-to-age` the host's SSH key, add it, `sops updatekeys` |
| service can't read the file | wrong `owner`/`group`/`mode`, or unit started before secrets were installed | fix permissions; order/restart the unit (`restartUnits`) |
| service keeps old value after edit | unit not tied to the secret's change | `restartUnits`/`reloadUnits`, or a `restartTriggers` hash |
| secret file mismatch fails evaluation | `validateSopsFiles = true` requiring the encrypted file in the store | add the file to git/store, or understand the check before disabling |
| password reset after each switch | `mutableUsers = false` (intentional) or wrong password option | expected under `mutableUsers = false`; otherwise use `hashedPasswordFile` |
| new user can't log in until reboot | `neededForUsers` missing for an activation-time password | set `neededForUsers = true` |

## Verification checklist

- `nix build`/`nix flake check` with **no** age key available succeeds.
- `ls -l /run/secrets/<name>` shows the declared owner and `0400`-style mode.
- `journalctl -b | grep -i sops` (or agenix unit) shows clean activation.
- The consuming unit is `active (running)` after the secret changed.
- A grep for `readFile`/`toString` over the config finds no secret paths.

## References

- `references/sops-agenix.md` — sops-nix and agenix option tables, `.sops.yaml`
  rules, key rotation, template secrets, and declarative password semantics.

## Sources

- sops-nix README: https://github.com/Mic92/sops-nix (accessed 2026-09-30)
- agenix README: https://github.com/ryantm/agenix (accessed 2026-09-30)
- NixOS manual, user management and password options: https://nixos.org/manual/nixos/stable/#sec-user-management (accessed 2026-09-30)
- sops key management: https://getsops.io/docs/usage/key-management/ (accessed 2026-09-30)
