---
name: nixos-deploy
description: Apply configuration with `nixos-rebuild` — switch/boot/test, generations, rollback, remote deploy, binary caches, distributed builds. Use when deploying to a machine, verifying an activation, wiring a cache or CI build, or setting up remote builders.
---

# Deploying NixOS configuration

Deployment is two questions: **where does the closure come from**, and **how
much of the machine does activating it touch**. Answer both before running
anything on a live host.

## Workflow

1. **Confirm deployability of the source.** If the target evaluates a flake
   from a repository (common: it pulls `github:org/repo#host`), the change
   must be committed *and pushed first*. Confirm `git status` is clean and the
   revision the host will fetch is the one you tested. Done when the source
   reference resolves to your change.
2. **Choose the rebuild verb** (see table). Start with `build`, then `test`,
   and only then persist. Done when you can say which failure window you are
   accepting.
3. **Predict substitution.** `nix build .#…config.system.build.toplevel
   --dry-run` shows what would be built versus substituted. If the closure is
   not on any cache the target trusts, decide the builder route *before*
   touching the host, not after. See `references/caches-and-builders.md`.
4. **Run the rebuild in the right place.**

   ```bash
   # On the host itself (preferred when the host pulls its own flake):
   ssh root@<host> 'nixos-rebuild switch --flake github:org/repo#<host>'

   # From a control machine (builds locally, copies, activates remotely):
   nixos-rebuild switch --flake .#<host> --target-host root@<host> \
     --build-host root@<builder>          # add --elevate=sudo on 26.11+ if needed

   # From a pre-built closure (CI path):
   nixos-rebuild switch --store-path /nix/store/<...>-nixos-system-<host>
   ```

   Done when the activation output reports the switch completed.
5. **Verify by observation.** On the host: `readlink /run/current-system`
   matches the built closure; `nixos-rebuild list-generations` marks it
   current; `systemctl --failed` is empty; each unit you changed is
   `active (running)` with a clean `journalctl -b -u <unit>`. Done when the
   *end state* is observed, never inferred from exit code.
6. **Know the way back.** Keep the previous generation as the rollback target
   (`nixos-rebuild switch --rollback`), and do not garbage-collect it until
   the new state has survived real use.

## Choose the verb

| Verb | Builds | Activates now | Becomes boot default | Use for |
|---|---|---|---|---|
| `build` | yes | no | no | proving the closure; no root needed |
| `dry-activate` | yes | prints planned changes | no | previewing unit/restart effects |
| `test` | yes | yes | no | low-stakes activation; reboot reverts |
| `boot` | yes | no | yes | kernel/bootloader/risky changes; activate on next reboot |
| `switch` | yes | yes | yes | normal deployment |

Kernel, initrd, and bootloader changes only take effect at reboot — `boot`
then reboot is the safe order. Interface renames and mount changes likewise
recommend `boot` + reboot.

## Generations and rollback

- `/nix/var/nix/profiles/system` points at the current generation;
  `system-<N>-link` are the others. `nixos-rebuild list-generations` lists
  dates, kernels, and the current one.
- `nixos-rebuild switch --rollback` re-activates the previous generation.
- `nix-env -p /nix/var/nix/profiles/system --delete-generations old` and
  `nix-collect-garbage -d` delete generations and rollback ability; they also
  require rebuilding for the boot loader entries to catch up.
- Boot loaders truncate entries with `configurationLimit` (systemd-boot:
  unlimited by default; GRUB: 100) — a generation can exist while being
  unbootable from the menu.

## Pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| host fails fetching the flake | change not committed/pushed | commit and push, re-run |
| switch hangs compiling on a small host | closure not substitutable, local build | pre-build on a stronger machine and push to a cache, or `--build-host` |
| `--target-host` fails with sudo/user errors | activation needs root; elevation flag changed in 26.11 (`--elevate`) | use root, or `--elevate=sudo`; `--use-remote-sudo` is a deprecated alias |
| remote activation killed mid-switch | SSH session drop | modern `nixos-rebuild` runs activation under `systemd-run`; for older tools use a tmux/screen session or `nixos-rebuild boot` |
| units failed but exit 0 | activation reports, does not fail loudly | treat `systemctl --failed` as the real status |
| machine rebuilds the same closure every time | impure evaluation or a floating ref | pin inputs; see `nix-flakes` |
| `--fast` unknown | flag not present in current nixos-rebuild (ng) | use `--no-reexec`; read `man nixos-rebuild` for your version |

## References

- `references/caches-and-builders.md` — substituters and trusted keys,
  `nix copy`, self-hosted caches, distributed builders and system features,
  and CI build/push/GC-root patterns.

## Sources

- NixOS manual, changing the configuration: https://nixos.org/manual/nixos/stable/#sec-changing-config (accessed 2026-09-30)
- NixOS manual, cleaning the store and rollback: https://nixos.org/manual/nixos/stable/#sec-nix-gc and #sec-rollback (accessed 2026-09-30)
- `nixos-rebuild` manual (26.05/26.11; nixos-rebuild-ng): https://nixos.org/manual/nixos/stable/ (accessed 2026-09-30)
- Nix manual, `nix copy`, `nix store verify`: https://nix.dev/manual/nix/stable/command-ref/new-cli/nix3-copy.html (accessed 2026-09-30)
