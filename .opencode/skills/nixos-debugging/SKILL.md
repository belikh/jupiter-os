---
name: nixos-debugging
description: Triage a failing NixOS build, evaluation, activation, or boot — error taxonomy, minimal reproduction, bisection, rollback. Use when a build or eval fails, a service won't start, or a host won't boot.
---

# Debugging NixOS failures

Two habits make NixOS debugging tractable: **bound the stage** (evaluation,
build, activation, runtime, boot fail for different reasons and have different
tools), and build a **tight loop** (one command that reliably reproduces *this*
failure) before theorising about a cure. If a live system is broken, recover
first with `references/recovery.md`, then diagnose calmly.

## Workflow

1. **Capture the failure verbatim.** The exact command, the full error text,
   and the stage it died at. Done when you can paste the failure without
   summarising it.
2. **Bound the stage** with the table below. Done when the stage is named and
   you know which skill owns the fix.
3. **Build the tight loop.** Narrow to the smallest command that reproduces *the
   same* failure — `nix eval`, `nix build .#attr -L`, `nixos-rebuild build`,
   `nixos-rebuild build-vm`, or the failing unit's `journalctl`. Done when the
   command is red reliably and quickly; this is the loop every later step runs.
4. **Read the evidence, not the story.** Evaluation: re-run with
   `--show-trace`. Build: `nix log` the failed derivation, read the phase that
   failed, not the last line. Activation/runtime: `journalctl -b -u <unit>`
   and `systemctl status`. Classify against
   `references/error-catalogue.md`. Done when the failing component is named.
5. **One hypothesis, one change.** Make the smallest change that tests the
   hypothesis; re-run the loop. Keep the changes separate so a fix is
   identifiable. Done when the loop goes green.
6. **Lock the fix in.** Add the reproduction to checks/tests where practical;
   never fix by disabling the check that caught it (`--no-build`,
   `doCheck = false` on a shared package, `NIXOS_NO_CHECK`, `|| true`).
7. **Deploy and verify by observation** — see `nixos-deploy`. Done when the
   original symptom is gone *and* the surrounding system is healthy
   (`systemctl --failed`, the unit is `active`, the running closure is the one
   you built).

## Bounding the stage

| Stage | Typical symptom | Tool | Fix owner |
|---|---|---|---|
| Evaluation | `error:` before any build; option/type errors, infinite recursion | `nix eval`, `nix flake check --no-build`, `--show-trace` | `nix-language`, `nixos-modules`, `nix-flakes` |
| Build | derivation fails, hash mismatch, phase error, missing header | `nix build .#… -L`, `nix log`, `--keep-failed`, `nix develop` | `nix-packaging` |
| Activation | switch output reports failed units; secrets missing; unit restarts | `nixos-rebuild test` first, `journalctl -b`, `systemctl status` | `nixos-deploy`, `nixos-secrets` |
| Runtime | system is up but a service misbehaves later | `journalctl -u`, `systemctl show`, `ss -tlnp` | service docs; often `nixos-modules` |
| Boot | no boot entry, kernel panic, hangs before `multi-user` | console, boot menu, `build-vm`, recovery | `nixos-hosts`, `references/recovery.md` |

Distinguish **deterministic** failures (same error every run — read it properly)
from **flaky** ones (order/timing/state dependent — reproduce by running the
failing path repeatedly and inspect concurrency or external state). Do not
"fix" a flaky failure with retries; find the coupling.

## Rules of evidence

- A green `nixos-rebuild switch` is not proof: activation can report failing
  units. Check `systemctl --failed` and the specific unit.
- `nixos-rebuild test` activates without touching the boot default — use it as
  the low-stakes loop for activation failures; a reboot reverts it.
- `nixos-rebuild build` and `build-vm` prove the closure and the boot path
  without touching the running system; prefer them while iterating.
- The error's *first* frame is usually the caller; the *last* file/attribute
  frame is the culprit.
- After a flake or input change, re-check the stage-1 assumption that new
  files are git-tracked (`git status --porcelain`, `git add` needed) before
  debugging anything else.

## Recovery pointer

If the machine is currently broken — service down, activation half-applied,
boot looping — stop diagnosing and recover: `references/recovery.md` covers
live rollback, boot-menu rollback, emergency/rescue targets, chroot repair
from an installer, and VM reproduction of a bad boot.

## References

- `references/error-catalogue.md` — stage-indexed catalogue: message shape →
  likely cause → next owner; read at step 4.
- `references/recovery.md` — getting a broken machine back to a known-good
  generation, then diagnosing from a safe base.

## Sources

- NixOS manual, troubleshooting and rollback: https://nixos.org/manual/nixos/stable/#ch-troubleshooting (accessed 2026-09-30)
- Nix manual, traces and logging: https://nix.dev/manual/nix/stable/command-ref/opt-common.html (accessed 2026-09-30)
- systemd debugging: `systemctl status`, `journalctl -b -u`, `systemd-analyze` (accessed 2026-09-30)
