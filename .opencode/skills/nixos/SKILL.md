---
name: nixos
description: Orientation map for this repo's NixOS skills suite — which skill to use for a task, and in what order. Use at the start of a multi-step NixOS task (new host, new service, broken build, secrets, deploy, upgrade) or when unsure which skill applies.
---

# NixOS skills — orientation map

This repo carries a suite of skills for NixOS work. Each specialist owns one
domain and is loadable by name with the `skill` tool. This page is the map:
pick by what you are about to do, not by which files you expect to touch.

## Pick the skill

| You are about to… | Load |
|---|---|
| Write or debug a Nix expression — laziness, `lib`, evaluation errors | `nix-language` |
| Touch `flake.nix`/`flake.lock` — inputs, follows, outputs, devShells | `nix-flakes` |
| Add or extend configuration — options, `mkIf`, types, priorities, imports | `nixos-modules` |
| Create a host — disks, boot, hardware config, first install | `nixos-hosts` |
| Package software, bump a version, fix a hash or build, write an overlay | `nix-packaging` |
| Something is broken — eval, build, activation, or boot | `nixos-debugging` |
| Apply config to a machine, roll back, set up caches or CI builds | `nixos-deploy` |
| Handle secrets — sops-nix/agenix, password hashes, activation-time values | `nixos-secrets` |
| Bump nixpkgs or inputs, triage a CVE, upgrade a release | `nixos-updates` |
| Review/audit a flake and its decisions, plan remediation | `nixos-review` |
| Configure user environments with Home Manager | `home-manager` |

## Common paths

- **New service on an existing host:** `nixos-modules` (write the option and
  module) → `nixos-debugging` if evaluation or the build fails → `nixos-deploy`
  (apply and verify).
- **New host:** `nixos-hosts` (disk layout, boot, host file) → `nixos-debugging`
  if the build or first boot misbehaves → `nixos-deploy`.
- **Bump and ship:** `nixos-updates` (decide what to bump and why) →
  `nix-flakes` when the lock/follows diff is unclear → `nixos-deploy` (canary
  one machine before the rest).
- **A build fails:** `nixos-debugging` first; it routes to `nix-packaging`,
  `nix-language`, or `nixos-modules` once the failing stage is known.
- **Audit before adopting or handing over:** `nixos-review` (defects,
  decisions, risks, remediation plan) → route each fix through the skill that
  owns it → `nixos-deploy` to apply, canary first.

## Cross-cutting rules

1. **Verify by observation, never by exit code.** A green build says a
   derivation succeeded, not that the service runs or the host boots.
2. **Bound the failure stage first.** Evaluation, build, activation, runtime,
   and boot have different tools; name the stage before reaching for one.
3. **Secrets are activation-time.** Never read a secret path at evaluation or
   build time; builds and CI must succeed with no decryption key present.
4. **The repo's own docs win.** When a project has stricter rules (module
   style, allowed patterns, banned packages), follow them over this suite's
   general advice — and when a rule must change, change the document first.
5. **Primary sources over recall.** NixOS moves fast: use the official manual,
   option search, and release notes linked from each skill, fetched now.

## Repo rule

Nothing in this suite encodes a particular repository's hosts, secrets,
credentials, or deployment topology. When working in a repository that has its
own `CLAUDE.md`/`AGENTS.md` or domain docs, read those first; they are
authoritative for that repository.
