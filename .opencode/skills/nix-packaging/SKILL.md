---
name: nix-packaging
description: Write derivations, packages, overrides, and overlays — `stdenv.mkDerivation`, fetchers, language builders. Use when packaging software, bumping a version, fixing a hash mismatch or build failure in a derivation, or adding an overlay.
---

# Packaging and derivations

A derivation is a pure function from inputs to a store path; the builder runs
in a sandbox with no network. The loop is: get the source in reproducibly, run
the right build system, declare inputs by role, then iterate with build logs
until the artefact lands in `$out`.

## Workflow

1. **Identify the build.** Read the upstream `README`/`Makefile`/`CMakeLists`:
   language, build system, dependencies, install step. Done when you can name
   the phases it needs.
2. **Write the skeleton** as a `callPackage`-style function:

   ```nix
   { lib, stdenv, fetchFromGitHub, cmake, ninja }:

   stdenv.mkDerivation (finalAttrs: {
     pname = "mytool";
     version = "1.2.3";
     src = fetchFromGitHub {
       owner = "org"; repo = "mytool"; tag = "v${finalAttrs.version}";
       hash = lib.fakeHash;                    # replaced after first failure
     };
     nativeBuildInputs = [ cmake ninja ];      # build-time tools
     buildInputs = [ ];                        # libraries linked/run
     meta = { description = "…"; homepage = "…"; license = lib.licenses.mit; mainProgram = "mytool"; };
   })
   ```

   Done when `nix build -f . mytool` reaches a phase failure rather than a
   parse error.
3. **Fill hashes from the error.** `lib.fakeHash` makes the build fail with
   `specified: … got: …`; paste the `got` value. Fetchers are fixed-output
   derivations — see `references/fetchers-and-hashes.md` for the exact
   commands and the auto-switching rules of `fetchFromGitHub`.
4. **Declare inputs by role.** Header-not-found at compile → `buildInputs`;
   command-not-found during build → `nativeBuildInputs`. Done when the build
   completes in the sandbox with no network.
5. **Iterate with logs.** `nix build -L .#…` streams the log; `nix log
   <drv>` reads a finished one; `nix develop` (or `--keep-failed` plus the
   `breakpointHook`) drops you into the failed sandbox. Done when the default
   output contains the programs you expect.
6. **Verify the artefact**, not the exit code: run it
   (`nix run .#… -- --version`), check `$out/bin`, `$out/share`, and that
   `meta.mainProgram` names the right binary.
7. **Pin the test seam.** Add cheap checks to `passthru.tests` for anything
   worth guarding; `nixpkgs-review` runs them when reviewing upstream PRs.

## Overrides and overlays

- `pkg.override { arg = …; }` re-calls the original function with named
  arguments — only for arguments the package declared.
- `pkg.overrideAttrs (finalAttrs: prevAttrs: { … })` changes derivation
  attributes and runs full `mkDerivation` processing (so `separateDebugInfo`
  and friends work). Prefer `finalAttrs` self-reference over `rec`.
- Overlays are `final: prev: { … }` functions applied in order to `pkgs`;
  reach for `final` when composing dependencies, `prev` when patching
  something that already exists. `nixpkgs.overlays` attaches them to a system.
- **A stdenv-level overlay cascades.** Rewriting `stdenv` (or a
  widely-consumed input) changes the derivation of nearly every package and
  everything downstream — binary caches match nothing and you rebuild the
  world. Override the single misbehaving package instead.

## Testing and inspection

```bash
nix build .#pkg -L                 # build, stream logs
nix build .#pkg --keep-failed      # keep the failed build dir for inspection
nix log .#pkg                      # log of the last build attempt
nix develop .#pkg                  # enter the build environment; --phase, --build, …
nix why-depends ./result /nix/store/path   # why is this in the closure
nix store diff-closures before after        # what a rebuild actually changed
nixpkgs-review pr 12345 --tests             # review an upstream change in-tree
```

## Pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `hash mismatch … specified: … got: …` | wrong or placeholder hash | paste the `got` hash; for fetchers, hash the *unpacked* output where required |
| `fatal error: x.h: No such file` | missing host dependency | add the library to `buildInputs` |
| `command not found` in the sandbox | missing build-time tool | add to `nativeBuildInputs` (and check `strictDeps`) |
| network access attempted in build | sandbox has no network | vendor, or add a fetcher phase (fixed-output derivations are the only networked builds) |
| `No rule to make target 'install'` | no install target | write `installPhase` with `runHook preInstall`/`postInstall` |
| works locally, fails in CI | undeclared input resolved from your shell | build with `--pure`/`nix build` only, fix `*Inputs` |
| package broken/eval refused | `meta.broken`, `meta.license`, known vulnerability | evaluate the underlying cause; allow unfree only deliberately (`config.allowUnfree`) |
| prebuilt binary in `$out` can't run | no interpreter/RPATH | `autoPatchelfHook` (native) plus runtime libs; `runtimeDependencies` for `dlopen` |
| rebuilds the world after an override | overlay touched `stdenv` or a shared dependency | override the leaf package only |

## References

- `references/fetchers-and-hashes.md` — fetcher selection, hash formats,
  prefetch commands, and the rules that keep hashes honest.
- `references/language-builders.md` — Go, Rust, Python, and JavaScript builder
  essentials with their typical first-build failures.

## Sources

- Nixpkgs manual, stdenv and phases: https://nixos.org/manual/nixpkgs/stable/#chap-stdenv (accessed 2026-09-30)
- Nixpkgs manual, fetchers and language builders: https://nixos.org/manual/nixpkgs/stable/#chap-pkgs-fetchers and languages sections (accessed 2026-09-30)
- nix.dev packaging tutorials: https://nix.dev/tutorials/packaging-existing-software (accessed 2026-09-30)
- Nix manual, `nix build`/`nix log`/`nix develop`: https://nix.dev/manual/nix/stable/command-ref/new-cli/ (accessed 2026-09-30)
