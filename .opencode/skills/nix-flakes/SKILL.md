---
name: nix-flakes
description: Work with `flake.nix` and `flake.lock` — inputs, follows, locking, outputs, devShells, and `nix flake` commands. Use when adding or bumping inputs, writing a new flake, or debugging flake evaluation and lock drift.
---

# Nix flakes

A flake is a directory with `flake.nix` whose outputs are a pure function of
its declared inputs, pinned in `flake.lock`. The mental model that prevents
most errors: **the lock graph is the source of truth for what is fetched, and
only git-tracked files exist to a git-backed flake**.

## Workflow

1. **Locate the flake root and its VCS state.** From the flake directory run
   `git rev-parse --show-toplevel` and `git status --porcelain`. A flake in a
   git repository sees **only tracked files**; a dirty tree warns, but a new
   untracked file is simply invisible. Done when you know whether `git add`
   is required before evaluation.
2. **Make the declaration change** in `flake.nix` (input, output, or follows).
3. **Regenerate the lock deliberately.** New input → `nix flake lock`; changed
   ref or bumped version → `nix flake update <input>`. Read the printed
   old→new revision diff, or `git diff flake.lock`. Done when the lock diff
   matches exactly the inputs you meant to touch.
4. **Verify resolution.** `nix flake metadata` prints the resolved and locked
   URLs and the input tree — this is the check that `follows` actually took
   effect. Done when the graph matches the intent.
5. **Evaluate and build the affected outputs.** `nix flake check --no-build`
   for evaluation; then build the specific output
   (`nix build .#packages.x86_64-linux.<name>`, `nixos-rebuild build` in a
   host repo). Done when the output builds, not merely evaluates.
6. **Commit `flake.nix` and `flake.lock` together.** A lockfile committed
   without its declaration change (or vice versa) is drift.

## Anatomy

```nix
{
  description = "…";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";  # a ref pins a branch
  inputs.other.follows = "nixpkgs";                          # deduplicate stores
  outputs = { self, nixpkgs, ... }: {
    packages.x86_64-linux.default = …;
    nixosConfigurations.host = nixpkgs.lib.nixosSystem { … };
    devShells.x86_64-linux.default = …;
    checks.x86_64-linux.eval = …;
    formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt;
  };
}
```

- `outputs` is a **function**; its argument names must match `inputs` keys.
  An input used only as a function argument may be omitted from `inputs` —
  flake will supply the default registry entry.
- Outputs have a schema: `packages.<system>.<name>`, `apps.<system>.<name>`,
  `devShells.<system>.<name>`, `checks.<system>.<name>`,
  `nixosConfigurations.<name>`, `overlays.<name>` (each a `final: prev:`
  function), `nixosModules.<name>`, `templates.<name>`, `formatter.<system>`.
- Flakes take **no parameters**; every output is keyed by system explicitly
  (`systems = [ "x86_64-linux" … ]` plus `genAttrs`, or flake-utils).

## Commands

| Command | What it does |
|---|---|
| `nix flake metadata` | resolve input graph; print locked URLs/revisions — the `follows` verifier |
| `nix flake show` | list outputs (`--all-systems`, `--json`) |
| `nix flake check` | validate output schema and **build `checks.<system>.*`**; `--no-build` to evaluate only; `--keep-going` |
| `nix flake lock` | add missing lock entries without changing existing pins |
| `nix flake update [input...]` | update all inputs, or only those named; `--commit-lock-file` commits the result |
| `nix flake archive --to ssh://host` | copy the flake plus all inputs to a store (remote evaluation) |
| `nix flake init` / `new` / `clone` / `prefetch` | scaffolding and prefetching |

Build/run through the flake: `nix build .#attr`, `nix develop .#attr`,
`nix run .#attr` (after `--`, arguments are passed through).

## Pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| "file not found" for a file that exists | flake is git-backed; file is untracked | `git add` it (or use `path:` for a deliberate non-git input) |
| `follows` seems ignored | lock graph not regenerated | `nix flake lock` / `nix flake update`; verify with `nix flake metadata` |
| `nix flake check` fails on a package you didn't test | check **builds** `checks.*` and unfree/unbuildable outputs | `--no-build`, or gate the check, or allow unfree deliberately |
| evaluation differs from a desktop shell | user nixpkgs config (`~/.config/nixpkgs`) is ignored by flakes | pass `config`/overlays explicitly in `import`/`nixosSystem` |
| works locally, fails in CI | `--impure` or an unpinned branch input | remove impure access; pin refs; run `git add` before CI |
| lock edited by hand then fetch errors | `narHash` no longer matches the tree | regenerate with `nix flake update <input>` rather than editing |
| `path:` input doesn't see changes | `path:` copies at evaluation; relative paths must stay in-tree | re-run the command; use `git+file:` semantics or commit for reproducibility |

**Status note (2026-09):** flakes remain an experimental feature upstream
(Nix 2.35 still warns; enable via `experimental-features = nix-command flakes`).
Lix froze the flake feature set and keeps it experimental by design. NixOS
26.05+ also offers a non-flake `system.nix` entry point. Behaviour below the
CLI may change; prefer documented commands over folklore.

## References

- `references/inputs-and-locking.md` — input types, `follows` mechanics, the
  lockfile format, registry, and pure-evaluation rules; read when crafting a
  non-trivial input graph or diagnosing lock drift.

## Sources

- Manual, `nix flake` and subcommands: https://nix.dev/manual/nix/stable/command-ref/new-cli/nix3-flake.html (accessed 2026-09-30)
- nix.dev, flakes concept: https://nix.dev/concepts/flakes (accessed 2026-09-30)
- nix.dev, pure evaluation and flake inputs: https://nix.dev/manual/nix/stable/command-ref/conf-file.html (accessed 2026-09-30)
- Nix release notes 2.35: https://nix.dev/manual/nix/latest/release-notes/rl-2.35.html (accessed 2026-09-30)
