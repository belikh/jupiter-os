# Error catalogue by stage

Language-level evaluation messages (syntax, types, recursion) are catalogued in
`nix-language/references/eval-errors.md`. This file covers the NixOS-shaped
failures: options, builds, activation, runtime, boot.

## Evaluation

| Message (shape) | Likely cause | Next |
|---|---|---|
| `The option 'x' does not exist … Did you mean` | typo, wrong namespace, declaring module not imported | `nixos-modules` |
| `conflicting definition values` | two equal-priority definitions | `nixos-modules` (priority reference) |
| `The option 'x' was accessed but has no value defined` | read without default or definition | `nixos-modules` |
| `infinite recursion encountered` during `nixos-rebuild` | `config` referenced in `imports`, `attrsOf`/`filterAttrs` cycle, unfixed self-reference | `nixos-modules`, `nix-language` |
| `file 'x' was not found in the Nix store` / stale file after adding it | flake sees only git-tracked files | `git add`; `nix-flakes` |
| `attribute 'x' missing` after an input bump | upstream rename/removal | read the release notes; `nixos-updates` |
| `error: … is marked as broken` / unfree refusal | `meta.broken` / `meta.license` | decide deliberately; `nix-packaging` |
| `experimental Nix feature 'x' is disabled` (e.g. `pipe-operators`, `nix-command flakes`) | feature flag not set | add to `experimental-features`; `nix-flakes` |

## Build

| Message (shape) | Likely cause | Next |
|---|---|---|
| `hash mismatch in fixed-output derivation` | wrong/stale hash, or wrong hashing method for the fetcher | paste `got`; `nix-packaging` fetchers reference |
| `error: builder for '…drv' failed` then a shell-like log | the real failure is inside the log | `nix log <drv>`, read the failing phase; `nix-packaging` |
| `fatal error: foo.h: No such file or directory` | missing host library | `buildInputs` |
| `command not found` during build | missing tool | `nativeBuildInputs` |
| `No such file or directory: …/bin/sh` from a prebuilt binary | interpreter not patched | `autoPatchelfHook`/`patchShebangs` |
| `error: cannot build '…' on this system` / `missing system features` | required feature (`gccarch-*`, `kvm`, `big-parallel`) unavailable | built-in local build / matching remote builder; `nixos-deploy` |
| disk filled mid-build | store out of space | `nix-collect-garbage -d`, check `/nix` size |
| `unpacker … cannot unpack` / `source root is …` | wrong fetcher or `sourceRoot` | `nix-packaging` fetchers reference |

## Activation

| Symptom | Likely cause | Next |
|---|---|---|
| unit restarts or fails right after switch | bad `ExecStart`, missing path, port conflict | `journalctl -b -u <unit>`; `nixos-modules` |
| permission denied reading a secret | wrong `owner`/`mode`, or secret installed after the unit started | `nixos-secrets` |
| service alive but serving old config | unit not restarted/reloaded on change | `restartUnits`/`restartTriggers`; `nixos-secrets`, `nixos-modules` |
| switch refuses with an inhibitor message | switch inhibitors (e.g. D-Bus/reboot-required changes) | reboot or override deliberately with `NIXOS_NO_CHECK=1` |
| activation output shows `Failed to restart …` but exit 0 | failures are reported, not fatal | treat as failure; check `systemctl --failed` |
| `/run/current-system` unchanged after switch | wrong `--flake` ref/profile | `nixos-deploy` |

## Runtime

| Symptom | Likely cause | Next |
|---|---|---|
| unit flapping (`systemctl show -p NRestarts`) | crash loop; read `journalctl -u` for the first crash | service/packaging fix |
| works after manual restart, not from boot | missing ordering (`after`/`wants`) or state | `nixos-modules` |
| port already in use | two services claim it, or a leftover process | `ss -tlnp`, fix module conflict |
| state lost on reboot | non-persistent path with impermanence | `nixos-hosts` impermanence reference |
| socket/permission errors only under systemd | hardening (ProtectSystem, DynamicUser) vs expected paths | adjust the unit deliberately |

## Boot

| Symptom | Likely cause | Next |
|---|---|---|
| loader menu has no new entry | loader not enabled/installed; EFI variables not written | `nixos-hosts` bootloaders reference |
| kernel panic: `Unable to mount root fs` | wrong root/device, missing module in initrd | console; `boot.initrd.*`; recovery |
| hangs before `multi-user` with `neededForBoot` mounts | persistent volume not available in stage 1 | mark `neededForBoot`; impermanence reference |
| boots older generation automatically | new generation failed to activate adequately | boot menu; recovery |
| black screen after bootloader | GPU/firmware regression after update | boot older generation, bisect; `nixos-updates` |

## Bisection tools

- **Generations:** compare `nixos-rebuild list-generations`, boot an older
  generation to confirm the regression window.
- **Closures:** `nix store diff-closures /nix/var/nix/profiles/system-<N>-link
  /nix/var/nix/profiles/system-<M>-link` shows exactly which packages/versions
  moved between two generations.
- **Git:** when the failure tracks a config change, `git bisect` over the
  configuration with `nixos-rebuild build` as the test is decisive.
- **Inputs:** `git diff flake.lock` dates a regression to an input bump; test
  by overriding that input.

## Sources

- NixOS manual, troubleshooting: https://nixos.org/manual/nixos/stable/#ch-troubleshooting (accessed 2026-09-30)
- Nix manual, `nix log`, `nix store diff-closures`: https://nix.dev/manual/nix/stable/command-ref/new-cli/ (accessed 2026-09-30)
- systemd manual (`systemctl`, `journalctl`): https://www.freedesktop.org/software/systemd/man/latest/ (accessed 2026-09-30)
