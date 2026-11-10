---
name: nixos-updates
description: Update flake inputs, nixpkgs pins, and NixOS releases; triage CVEs. Use when bumping nixpkgs, reacting to a security advisory, planning a release upgrade, or deciding what a rebuild changed.
---

# Updates and security

Update deliberately: change one input at a time where possible, read the
revision diff, look at what actually changed in the closure, verify, then roll
out to one machine before the rest. "The update command exited 0" is the start
of the evidence, not the end.

## Workflow

1. **Baseline first.** Record the current pinned revisions (`nix flake
   metadata`), the running generation (`nixos-rebuild list-generations`), and
   a green evaluation/build. Without a baseline a later failure cannot be
   attributed. Done when you can say exactly what was working before.
2. **Scope the bump.** Prefer `nix flake update <input>` (one input) over a
   blanket update while investigating; list updates separately in the commit
   message. Read the printed old→new revisions, and `git diff flake.lock` for
   the graph. Done when every changed input is named.
3. **Read what changed.** For a nixpkgs/OS bump, read the release notes
   (including "highlights" and "backward incompatibilities"). For a package
   bump, read upstream release notes. Done when you know whether this is a
   routine bump or a migration.
4. **See the closure impact** before deploying:
   `nix store diff-closures /nix/var/nix/profiles/system-<old>-link
   /nix/var/nix/profiles/system-<new>-link` lists added/removed/upgraded
   packages between generations. Kernel or initrd changes shift to the
   `nixos-rebuild boot` path. Done when you know whether a reboot is required.
5. **Verify the build, then canary.** `nix flake check --no-build` (or your
   repo's equivalent), build one host, deploy it with `nixos-rebuild boot`
   when boot-relevant, observe it, then proceed to the rest. See
   `nixos-deploy` for the deploy/verify discipline.
6. **Keep the way back.** Do not garbage-collect the previous generation until
   the update has survived real use. All inputs and generations are rollback
   targets; `nix-collect-garbage -d` deletes generations.

## Release upgrades

- NixOS releases every six months: `YY.05` and `YY.11`. Move the channel
  (`nix-channel --add https://channels.nixos.org/nixos-26.05 nixos`) or the
  flake branch pin (`nixos-26.05`), then rebuild. Read the release-notes
  appendix first.
- `system.stateVersion` stays at its **original** value forever. It gates
  data-format defaults for stateful services and is not a version marker;
  changing it can break services or trigger migrations. The release upgrade
  changes the pin, not this value.
- `system.autoUpgrade` schedules the same operation on the host:
  `dates` (systemd.time), `operation = "switch" | "boot"`, `flake` or
  `channel`, `allowReboot`, `rebootWindow`, and `randomizedDelaySec` for
  staggering a fleet. Automatic is not verified — decide the observation
  policy deliberately.
- Kernel, initrd, and bootloader changes take effect on reboot: prefer
  `nixos-rebuild boot` + reboot, keeping the old generation bootable.

## Security-driven updates

Trigger one with a real advisory, not a scanner's raw match. In short (full
procedure in `references/cve-triage.md`):

1. Establish the actual installed version.
2. Compare against the advisory's affected and fixed versions, allowing for
   backported patches (a version number alone does not prove vulnerability).
3. Choose the smallest fix: nixpkgs input bump, targeted patch, or
   configuration mitigation.
4. Record the decision and evidence; a deferral gets a date and a trigger.

## Pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| update evaluated then failed to build | full-graph bump, one breakage | attribute by input with `git diff flake.lock`; revert/override the single input |
| "everything updated at once" is unattributable | blanket `nix flake update` | bump inputs individually when triaging |
| service data broken after release upgrade | `stateVersion` changed alongside it | restore the original value |
| new defaults surprise you after kernel/initrd update | reboot not done | `boot` + reboot; check `uname -r` against the generation |
| binary cache misses on every bump | pinned to an arbitrary revision not built by the cache | prefer release branches, or pre-build and cache; see `nixos-deploy` |
| CVE scanner flags a package you do not ship | heuristic name/version matching | verify the closure with `nix why-depends`; see triage reference |
| rollback impossible after a bad update | old generation garbage-collected | keep generations until verified; pin important closures as GC roots |
| unstable branch pin drifts under you | branch ref moves on fetch | the lockfile pins the revision; update deliberately |

## References

- `references/cve-triage.md` — the security tracker workflow, scanner caveats,
  version verification with backports, and the resolution routes.

## Sources

- NixOS manual, upgrading: https://nixos.org/manual/nixos/stable/#sec-upgrading (accessed 2026-09-30)
- NixOS manual, `system.autoUpgrade`: https://nixos.org/manual/nixos/stable/options#opt-system.autoUpgrade (accessed 2026-09-30)
- `system.stateVersion`: https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion (accessed 2026-09-30)
- Nixpkgs security tracker: https://tracker.security.nixos.org/ (accessed 2026-09-30)
- `vulnix`: https://github.com/nix-community/vulnix (accessed 2026-09-30)
- RFC 0026 (staging workflow): https://github.com/NixOS/rfcs/blob/master/rfcs/0026-staging-workflow.md (accessed 2026-09-30)
