# Fetchers and hashes

Fetchers are **fixed-output derivations**: a hash declares exactly what the
result is, so the build may use the network, and any parameter change without
a hash update silently reuses the old store object. Treat hashes as part of
the specification.

## Choose the fetcher

| Source | Fetcher | Notes |
|---|---|---|
| single file URL | `fetchurl` | `url` or `urls`; `name` defaults to the basename |
| archive to unpack | `fetchzip` | `stripRoot = true`; hash the unpacked tree |
| GitHub release/tag | `fetchFromGitHub` | owner/repo/rev or tag; tarball of the commit |
| GitLab | `fetchFromGitLab { domain; owner; repo; rev; }` | subgroups need escaping in URLs |
| Gitea/Forgejo/Codeberg | `fetchFromGitea`/`fetchFromForgejo`/`fetchFromCodeberg` | |
| SourceHut | `fetchFromSourcehut` | |
| any git repo | `fetchgit` | full clone control: `fetchSubmodules`, `fetchLFS`, `sparseCheckout`, `rootDir`, `leaveDotGit`, `deepClone` |
| raw local path | none — `src = ./src;` | copied to the store at evaluation |

`fetchFromGitHub` **auto-switches to `fetchgit`** when you pass `forceFetchGit`,
`fetchSubmodules`, `fetchLFS`, `leaveDotGit`, `deepClone`, `sparseCheckout`, or
`rootDir`. When the auto-switch happens, the hash must be computed with the
matching method (`nix-prefetch-git`), or the build fails with a hash mismatch.

## Compute a hash

```bash
nix-prefetch-url https://example.com/file.tar.gz            # legacy nix32 output
nix-prefetch-url --unpack https://example.com/src.tar.gz    # hash of the unpacked tree (fetchzip/fetchFromGitHub)
nix store prefetch-file https://example.com/file            # SRI format by default
nix store prefetch-file --json --hash-type sha256 <url>     # machine-readable
nix hash convert --from nix32 --to sri <hash>               # convert old form
nix-prefetch-git https://host/repo <rev>                    # git-sourced hash
```

- **SRI** (`sha256-<base64>`) is the modern spelling and what nixpkgs accepts
  everywhere; legacy nix32 (base32) still works.
- `lib.fakeHash` (or `lib.fakeSha256`) is the only safe placeholder — any
  *other* wrong hash makes `fetchurl` fall back to an insecure fetch path
  instead of failing honestly.
- Failure shape, then fix:

  ```
  error: hash mismatch in fixed-output derivation '…-source.drv':
           specified: sha256-AAAA…
              got:    sha256-BBBB…
  error: build of '…-source.drv' failed
  ```

  Paste `got`. If the *same* URL keeps producing different hashes, the source
  is not reproducible (regenerated tarballs, timestamps) — switch to
  `fetchgit` or an `--unpack` hash.

## Hash-update workflow for a version bump

1. Change `version` (and `src` tag/rev).
2. Run the build; copy `got` into `hash`.
3. If the package vendors dependencies (Go `vendorHash`, Rust `cargoHash`,
   npm `npmDepsHash`), the *dependency* hash will also be stale — paste the
   new one the same way. Those hashes cover only the dependency set, so a
   pure version bump with unchanged deps leaves them valid.
4. Rebuild twice: the second build must be a no-op (same hash, no rebuild).

## Sources

- Nixpkgs manual, fetchers: https://nixos.org/manual/nixpkgs/stable/#chap-pkgs-fetchers (accessed 2026-09-30)
- Nix manual, `nix store prefetch-file`, `nix hash convert`: https://nix.dev/manual/nix/stable/command-ref/new-cli/nix3-store-prefetch-file.html (accessed 2026-09-30)
- nix.dev, packaging tutorial (hashes in practice): https://nix.dev/tutorials/packaging-existing-software (accessed 2026-09-30)
