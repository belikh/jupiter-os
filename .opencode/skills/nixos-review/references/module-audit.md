# Module and configuration audit

Criteria for the module/host dimension of `nixos-review`. Each row:
**check → detect → severity**. Sources accessed 2026-09-30.

## Interface design

| Check | Detect | Severity |
|---|---|---|
| No options declared but never set anywhere (dead interface) unless published for consumers | `nixos-option -r --flake .#<host>` or inspect `options.*.isDefined`/`definitions`; intersect with usage | major if internal-only |
| Every cross-host service module has an `enable` toggle | `rg 'mkEnableOption'` in each module; a module without one cannot be opted out | major |
| Package choices are options, not hard-coded | `rg 'pkgs\.[a-zA-Z]' modules/` where `mkPackageOption` is absent | major |
| Structural config uses `settings` (RFC 0042), not stringly `extraConfig` | `rg 'extraConfig\|extraOptions'` | major for new modules |
| Flags carry documentation and constraints | `mkOption { type; description; example; }` present; no `type = types.anything` without reason | major |
| Defaults do not hide required decisions (hostname, disk, user, secret path) | read defaults; placeholders like `"REPLACE-ME"` | major |
| Visibility used as intended (`internal`, `visible`, `readOnly`) | `rg 'internal\s*=\|visible\s*=\|readOnly\s*='` | minor |

## Implementation correctness

| Check | Detect | Severity |
|---|---|---|
| `mkIf` used for config-dependent conditions; no `config = if config.…` at module top level | `rg 'config = if \|config = [^;]*if config\.'` | blocker when it recurses, major otherwise |
| `imports` never references `config` (imports resolve before the fixpoint) | `rg 'imports.*config\.'` | blocker |
| `with lib;`/`with pkgs;` not used for scoping | `rg '^with (lib\|pkgs);'` | minor–major (origin loss, shadowing) |
| `freeformType` confined to submodules, not public option trees | `rg 'freeformType'` | major |
| `types.attrs` replaced by `attrsOf anything` (attrs silently drops definitions and ignores `mkIf`/`mkDefault`) | `rg 'types\.attrs\b'` | major |
| Assertions guard mutually exclusive config; warnings only advise | `rg 'assertions =\|warnings ='` | major if unguarded |
| Renamed/removed options carry `mkRenamedOptionModuleWith`/`mkRemovedOptionModule` | `git log -p` for option path changes; grep shims | major (silent breakage) |
| `disabledModules` entries still correspond to real modules with replacements imported | `rg 'disabledModules'` | minor |

## Priority hygiene

| Check | Detect | Severity |
|---|---|---|
| `mkForce` reserved for genuinely required values, not to win fights | `rg 'mkForce'`; inspect reason and `highestPrio` | blocker when a user option becomes unoverridable, major otherwise |
| `mkDefault` used for overridable suggestions; required values defined plainly | `rg 'mkDefault'`; check comments | major |
| The winning definition of critical options is intended | `nixos-option <path>` lists definitions and files | major |
| List merges (`mkBefore`/`mkAfter`) not used where replacement was intended | `rg 'mkBefore\|mkAfter'` | major when duplicates reach units/flags |
| Cross-module ordering is explicit, not implicit in definition order | comments like "must come after"; prefer `mkOrder`/unit ordering | minor–major |

## Host composition

| Check | Detect | Severity |
|---|---|---|
| Shared behaviour lives in enable-gated modules, not copy-pasted host blocks | diff `hosts/*/configuration.nix` pairs | major (drift) |
| Host deviations from the shared pattern have a written reason | inline comments / ADRs | major when undocumented |
| `hardware-configuration.nix` edits are minimal and annotated | `git log -p` on the file; generated-file warning | major |
| `system.stateVersion` present, plausible, unchanged | `rg stateVersion`; history | blocker if changed/missing |
| `specialArgs` only for values needed while resolving `imports`; rest via `_module.args`; `lib` not overridden | `rg 'specialArgs\|_module.args'` in `flake.nix` | major |
| `extraModules`/`modules` composition does not hide which host gets what | read `nixosSystem` calls; magic injection is a smell | minor–major |
| No never-imported modules (dead code that will rot) | intersect files declaring options with the import closure from `flake.nix` → hosts → modules | minor |

## Operability of modules

| Check | Detect | Severity |
|---|---|---|
| Services that read generated config set `restartTriggers`/`reloadTriggers` | compare unit config to what it consumes | major (edits never take effect) |
| Boot services have `wantedBy`/dependency targets | default is empty — grep service blocks | major (never starts) |
| Ordering pairs `after` with `wants`/`requires`/`bindsTo` | grep `after =` and check the counterpart | major where races exist |
| Timers that own catch-up/coordination set `Persistent` and jitter | grep `timerConfig` | minor–major |
| Generated files owned/moded for their consumer | cross-check `environment.etc.*` user/group/mode vs service user, `StateDirectory` | major |
| `/etc` never carries secret material (world-readable store symlinks) | `rg 'environment\.etc'` then trace inputs from secret paths | blocker |

## Review technique

- Enumerate the real option tree: `nixos-option -r --flake .#<host>` or
  `nix eval .#nixosConfigurations.<h>.options` (each option exposes
  `declarations`, `definitions`, `isDefined`, `highestPrio`).
- Compare hosts for drift: diff the host files; compare
  `nix eval .#nixosConfigurations.<h>.config.system.build.toplevel.drvPath`,
  `nix store diff-closures`, `nixos-rebuild dry-build`/`dry-activate`.
- Documentation drift is a finding: every path, host, option, or command a
  README/CLAUDE.md names must resolve against the code; a stale claim that
  would misdirect an operator or an agent is **major**.
- Attribution rule: a `with lib;` or `mkForce` that a repo documents as house
  style is that repo's choice (review it as a decision, not a defect); the
  same construct unexplained and widespread is a finding.

## Sources

- NixOS manual, writing modules, option declarations/definitions/types,
  freeform modules, assertions, replace modules, unit handling: https://nixos.org/manual/nixos/stable/#sec-writing-modules (accessed 2026-09-30)
- Nixpkgs manual, module system: https://nixos.org/manual/nixpkgs/stable/#module-system (accessed 2026-09-30)
- RFC 0042 (option naming, `settings` pattern): https://github.com/NixOS/rfcs/blob/master/rfcs/0042-config-option.md (accessed 2026-09-30)
- RFC 0088 (nixpkgs breaking-change policy): https://github.com/NixOS/rfcs/blob/master/rfcs/0088-nixpkgs-breaking-change-policy.md (accessed 2026-09-30)
- nixpkgs `nixos/README.md`, `lib/options.nix`, `lib/modules.nix` (implementation metadata, priorities): https://github.com/NixOS/nixpkgs (accessed 2026-09-30)
- systemd unit/timer semantics: https://www.freedesktop.org/software/systemd/man/latest/systemd.unit.html and systemd.timer.html (accessed 2026-09-30)
