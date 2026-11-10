# Flake, inputs, purity, reproducibility audit

Criteria for the flake-structure and reproducibility dimension of
`nixos-review`. Each row: **check → detect → why → severity** (blocker /
critical / major / minor). All sources accessed 2026-09-30.

## Outputs and structure

| Check | Detect | Severity |
|---|---|---|
| `formatter` output exists (RFC 166 formatting is reproducible) | `nix flake show --json \| jq '.formatter'` → null | minor |
| `checks` exist and test something real (trivial `true` checks are theatre) | `nix eval --json .#checks.<system> --apply builtins.attrNames`; inspect each | major for system repos |
| `nixosConfigurations` names match `hosts/` directory | `nix eval --json .#nixosConfigurations --apply builtins.attrNames` vs `ls hosts/` | minor, but breaks deploy scripts |
| Exported modules surfaced (`nixosModules`) when the repo is a module source | `nix flake show --json \| jq '.nixosModules'` | major for module repos |
| No legacy output names (`defaultPackage`, `devShell`, `overlay`, `nixosModule`) | `rg 'defaultPackage\|devShell\s*=\|overlay\s*=\|nixosModule\s*=' flake.nix` | minor |
| Entry point thin — logic in imported files, not in `flake.nix` | `wc -l flake.nix`; read; flake-parts or plain imports | major over a few hundred lines |
| Per-system outputs complete for every system hosts use | `nix flake show --all-systems --json`; compare to `nixosConfigurations.*.pkgs.stdenv.hostPlatform.system` | major when a host's system has no `packages`/`checks` |

## Inputs and locking

| Check | Detect | Severity |
|---|---|---|
| `flake.lock` committed and in sync | `git ls-files --error-unmatch flake.lock`; `nix flake lock --no-update-lock-file` (or a `--no-write-lock-file` build) | blocker if absent |
| No dirty locks | `rg '"dirtyRev"\|"dirtyShortRev"\|allow-dirty-locks' flake.lock .` | major |
| Every input consumed by the code; no dead inputs | `rg '<input>\.' --glob '!flake.lock'`; unused-input actions | minor |
| Duplicate nixpkgs instances followed or justified | `nix flake metadata --json \| jq '[.locks.nodes[] \| select(.locked.repo?=="nixpkgs")] \| length'` | major for un-followed duplicates, minor otherwise |
| `follows` complete and not over-applied | `nix flake metadata` shows `follows input …` lines; check each nixpkgs-bearing input | major |
| No `path:`/absolute-url inputs in a shared flake | `rg 'url = "path:\|url = "/' flake.nix` | blocker for public flakes, minor for private one-machine repos |
| No reliance on registry indirection for composition | `jq '[.locks.nodes[]? \| select(.original.type?=="indirect")]' flake.lock` | major |
| Floating branch refs acceptable because the lock pins; lock reviewed per bump | `nix flake update` diffs in history; `--refresh` only where intended | major if lock unused/dirty |
| Pinning matches deploy reality — no `--override-input` in CI/deploy scripts | `rg -- '--override-input' .github Makefile justfile scripts/` | major |
| Inputs current: not EOL, not stale beyond policy | `nix flake metadata --json` `lastModified` per node; compare release support status | major if EOL |

## Purity and hermeticity

| Check | Detect | Severity |
|---|---|---|
| No impure constants | `rg 'getEnv\|currentSystem\|currentTime\|nixPath\|storePath'` | blocker unless the flake is explicitly impure |
| No unhashed eval-time fetches | `rg 'builtins\.(fetchurl\|fetchTarball\|fetchGit)'`; require `sha256`/`rev` | major |
| `readFile` only on in-tree or declared-input paths | `rg 'readFile'` and trace each argument | major |
| No `import <nixpkgs>` / `NIX_PATH` dependence | `rg 'import <nixpkgs>\|NIX_PATH'` | major |
| No `--impure` in CI, Makefiles, deploy scripts | `rg -- '--impure' .github Makefile justfile scripts/` | blocker in CI/deploy |
| No IFD where eval must stay hermetic | re-evaluate with `--option allow-import-from-derivation false`; `rg 'import \(.*(runCommand\|derivation)'` | major |
| No secrets in eval (flake source is world-readable in the store) | `rg -in 'password\|token\|api[_-]?key\|secret' --type nix` then trace | blocker on a real value |

## Verification level (what green means)

| Check | Detect | Severity |
|---|---|---|
| CI is not eval-only | grep workflows for `--no-build` as the only gate; check for `nix build .#nixosConfigurations.<h>.config.system.build.toplevel` | major |
| Multi-system coverage | `--all-systems` present for multi-arch fleets | major when hosts are unverified |
| Boot-sensitive changes have a VM test or documented manual boot check | `nixos-rebuild build-vm` in CI/docs; `checks` containing VM tests | major |
| Closure substitutability is known | `nix build --dry-run` for each host; `nix path-info -r --store https://cache.nixos.org/ <toplevel>` | major if core paths must build locally |
| Cache hostility is intentional and documented | overlays touching glibc/openssl/stdenv/systemd; blanket `doCheck = false`; `gccarch-*`; unfree/insecure | blocker for glibc/stdenv tampering, major for tuning |
| Kernel strategy is cache-compatible | `rg 'kernelPackages\|structuredExtraConfig\|kernelPatches'`; ZFS hosts need a compatible stock kernel | major; blocker if ZFS + unsupported kernel refuses to eval |
| Lock-only build works | `nix build .#host --no-write-lock-file` (or `nix flake check --no-write-lock-file`) | blocker when it fails |
| Formatting enforced in CI | `nix fmt` / `nixfmt --check` step; `formatter` output present | minor |

## State and tooling

| Check | Detect | Severity |
|---|---|---|
| `system.stateVersion` explicitly set per host, `YY.MM`, unchanged | `rg stateVersion`; `git log -p` for changes | blocker if changed/missing on stateful hosts |
| Stateful service migrations accounted for (PostgreSQL majors, Nextcloud) | compare `services.*.package` to `stateVersion`; read release notes before bumps | blocker if skipped majors |
| Linters as aids, not verdicts | `statix`, `deadnix`, `nixpkgs-hammering` runs recorded with the rest of the evidence | minor |
| Docs state the verification level honestly | README/CLAUDE claims ("CI passing") reconcile with what CI runs | major when overstated |

## Audit commands to record in the baseline

```bash
nix flake metadata --json
nix flake show --all-systems --json
nix flake check --no-build            # eval only; say so in the report
git ls-files flake.lock && git status --porcelain
rg -n 'getEnv|currentSystem|currentTime|readFile|--impure|path:|builtin' --type nix
rg -n 'kernelPackages|gcc\.arch|gccarch|doCheck = false|allowUnfree|permittedInsecure' .
```

## Sources

- Nix manual, `nix flake` subcommands (show/check/metadata/lock/update): https://nix.dev/manual/nix/stable/command-ref/new-cli/nix3-flake.html (accessed 2026-09-30)
- Purity and builtins (`currentSystem`, `currentTime`, `getEnv`, fetch functions): https://nix.dev/manual/nix/stable/language/builtins.html (accessed 2026-09-30)
- IFD and `allow-import-from-derivation`: https://nix.dev/manual/nix/stable/language/import-from-derivation.html (accessed 2026-09-30)
- nix.dev, flakes concept and status: https://nix.dev/concepts/flakes (accessed 2026-09-30)
- Lix flakes freeze: https://wiki.lix.systems/books/lix-contributors/page/flakes-feature-freeze (accessed 2026-09-30)
- RFC 0026 (staging; why mass rebuilds lag caches): https://github.com/NixOS/rfcs/blob/master/rfcs/0026-staging-workflow.md (accessed 2026-09-30)
- RFC 0166 (nixfmt): https://github.com/NixOS/rfcs/blob/master/rfcs/0166-nix-formatting.md (accessed 2026-09-30)
- nixpkgs `make-derivation.nix` (doCheck, gccarch `requiredSystemFeatures`): https://github.com/NixOS/nixpkgs/blob/master/pkgs/stdenv/generic/make-derivation.nix (accessed 2026-09-30)
- `version.nix` (`stateVersion` semantics): https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/misc/version.nix (accessed 2026-09-30)
- ZFS on NixOS (kernel compatibility): https://wiki.nixos.org/wiki/ZFS (accessed 2026-09-30)
- NixOS wiki, Binary Cache: https://wiki.nixos.org/wiki/Binary_Cache (accessed 2026-09-30)
- deadnix/statix/nixpkgs-hammering: https://github.com/astro/deadnix, https://github.com/molybdenumsoftware/statix, https://github.com/jtojnar/nixpkgs-hammering (accessed 2026-09-30)
