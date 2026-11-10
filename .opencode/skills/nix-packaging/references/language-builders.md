# Language builders

All of these wrap `stdenv.mkDerivation` with the language's build system
configured; their extra attributes exist to pin downloaded dependency sets.
The dependency hash is the usual first-build failure — copy `got` and move on.

## Go — `buildGoModule`

```nix
buildGoModule {
  pname = "tool"; version = "1.0.0";
  src = …;
  vendorHash = lib.fakeHash;   # hash of the go modules; null if ./vendor is committed
  # proxyVendor = true;        # fetch modules via the module proxy (needed for some module graphs)
  # subPackages = [ "cmd/tool" ];
  # ldflags = [ "-s" "-w" "-X main.version=${version}" ];
  env.CGO_ENABLED = "0";       # 25.11+: set via env, a bare CGO_ENABLED errors
}
```

- `vendorHash = null` requires a committed `vendor/` directory.
- Version stamps go through `ldflags`; the variable path is package-specific —
  read `main.go`.
- Builds are CGO-free by default in the sandbox; set `env.CGO_ENABLED = "1"`
  only with the needed `buildInputs`.

## Rust — `rustPlatform.buildRustPackage`

```nix
rustPlatform.buildRustPackage {
  pname = "tool"; version = "1.0.0";
  src = …;
  cargoHash = lib.fakeHash;    # hash of all crate sources
  # or, preferred for large dependency graphs:
  # cargoLock = { lockFile = ./Cargo.lock; outputHashes = { "gitdep-1.0.0" = "sha256-…"; }; };
}
```

- `cargoLock` reads the upstream lockfile and only needs `outputHashes` for
  **git dependencies** — those fail before building if missing.
- If the repo has no `Cargo.lock`, generate one in `postPatch`.
- Builds are offline: any dependency not in the hash fails, not falls back.

## Python — `buildPythonPackage` / `buildPythonApplication`

```nix
python3.pkgs.buildPythonApplication {
  pname = "tool"; version = "1.0.0";
  src = …;
  pyproject = true;            # 26.05: the only supported build-system style
  build-system = [ setuptools ];        # or hatchling, poetry-core, …
  dependencies = [ requests ];
  nativeCheckInputs = [ pytestCheckHook ];
  pythonImportsCheck = [ "tool" ];
}
```

- In nixpkgs 26.05, `python3` is CPython 3.13 and `python3Packages` is the
  3.13 set; old `format = "setuptools"`-style attributes are deprecated.
- Checks run by default (`doCheck = true`); use `pytestFlags`-family options
  rather than `pytestFlagsArray` (now an error).
- `pythonRelaxDepsHook` handles over-strict `pyproject.toml` bounds.

## JavaScript — `buildNpmPackage` (and friends)

```nix
buildNpmPackage {
  pname = "ui"; version = "1.0.0";
  src = …;
  npmDepsHash = lib.fakeHash;  # compute with: prefetch-npm-deps package-lock.json
  npmBuildScript = "build";    # default
  makeCacheWritable = true;    # when the build writes into node_modules
}
```

- `importNpmLock` avoids the hash entirely by consuming `package-lock.json`.
- 26.05: `npmDepsFetcherVersion = 2` fixes npm workspaces; Node 24 is the
  default.
- pnpm: `fetchPnpmDeps` (+ hooks) with `fetcherVersion = 3`.
- Yarn v1: `fetchYarnDeps` + `yarnConfigHook`/`yarnBuildHook`/
  `yarnInstallHook`. **`mkYarnPackage`/`yarn2nix`/`nodePackages` were removed
  in 26.05** — port to the hook-based fetchers.

## Cross-cutting notes

- `doCheck` defaults to false for `stdenv` builds but true for Python; checks
  never run when cross-compiling.
- `passthru.tests` is the place for expensive or integration tests: an attrset
  of derivations that build iff the tests pass, picked up by `nixpkgs-review
  --tests`.
- `strictDeps = true` (default in Go/Rust/Python builders) removes native
  leniency and exposes wrong `buildInputs`/`nativeBuildInputs` splits.
- Binary releases: `autoPatchelfHook` in `nativeBuildInputs` rewrites
  interpreter/RPATH; list dynamic-load libraries in `buildInputs` and
  `runtimeDependencies` for `dlopen` cases.

## Sources

- Nixpkgs manual, language-specific builders: https://nixos.org/manual/nixpkgs/stable/#part-builders (accessed 2026-09-30)
- Nixpkgs 26.05 release notes (Python 3.13, yarn removal, Go env, npm): https://nixos.org/manual/nixpkgs/stable/release-notes (accessed 2026-09-30)
- nix.dev, Go/Rust/Python packaging tutorials: https://nix.dev/tutorials/ (accessed 2026-09-30)
