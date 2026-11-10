# Flake inputs and locking

## Input types

| Type | Example | Notes |
|---|---|---|
| `indirect` | `nixpkgs` (bare name) | resolved through the registry |
| `github` | `github:owner/repo/ref?rev=…` | downloads a **tarball** — no history; `?ref=` is a branch or tag, `?rev=` a commit; GitHub allows rev without ref |
| `git` | `git+https://host/repo?ref=main` | real clone; with `?rev=`, the rev must be reachable from `ref` |
| `gitlab` / `sourcehut` | similar | GitLab subgroups need `%2F` (`group%2Fsubgroup`) |
| `path` | `path:../local` | arbitrary local directory; copied at evaluation |
| `git+file` | `git+file:///path/repo` | git semantics; **tracked files only**; dirty trees warn |
| `tarball` / `file` | URL to an archive | fixed content |

Sources without `flake.nix` need `flake = false;` in the input attrset, which
exposes the tree as a path rather than flake outputs.

## `follows`: sharing one nixpkgs

A dependency's own `nixpkgs` input normally implies a second copy. `follows`
rewrites an edge in the lock graph to point at yours:

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  home-manager.url = "github:nix-community/home-manager/release-26.05";
  home-manager.inputs.nixpkgs.follows = "nixpkgs";
};
```

- Paths are relative to the **root** flake, `/`-separated:
  `inputs.hyprland.inputs.nixpkgs.follows = "nixpkgs"`.
- Nested: `inputs.nixops.inputs.nixpkgs.follows = "dwarffs/nixpkgs"` follows a
  *sibling's* nixpkgs.
- Overriding instead of following: assign a full input value
  (`inputs.nixops.inputs.nixpkgs = { … };`).
- `follows` is a **rewrite of the graph**; it only takes effect when the
  lockfile is regenerated (`nix flake lock` / `nix flake update`), and
  `nix flake metadata` is the proof it did.

## The lockfile

`flake.lock` is JSON, format version 7 (current in Nix 2.34–2.35):

```json
{
  "nodes": {
    "nixpkgs": {
      "locked": {
        "lastModified": 0,
        "narHash": "sha256-…",
        "owner": "NixOS", "repo": "nixpkgs", "rev": "…", "type": "github"
      },
      "original": { "owner": "NixOS", "repo": "nixpkgs", "type": "github" }
    },
    "root": { "inputs": { "nixpkgs": "nixpkgs" } }
  },
  "root": "root",
  "version": 7
}
```

- `original` is what you asked for; `locked` is what was fetched and is passed
  to `outputs`.
- `root` has no `original`/`locked` (it is this flake). Nodes are named
  `root`, then input names; collisions get suffixes.
- Locking a **dirty** local input by NAR hash requires
  `allow-dirty-locks = true` (default `false`) and is only for local testing.
- Do not hand-edit `narHash`; regenerate instead.

## Locking commands in detail

```bash
nix flake lock                                   # create missing entries only
nix flake update                                 # update every input
nix flake update nixpkgs                         # update one input
nix flake update --flake /path/to/flake          # another directory
nix flake update --commit-lock-file              # commit the result (message configurable)
nix flake lock --override-input nixpkgs …        # temporary override, does not write the lock
nix flake metadata --json | jq .locks            # inspect the graph
```

Deprecated: `--recreate-lock-file`, `--update-input` (use `update`).
`--no-write-lock-file` evaluates against the existing pins — useful in CI to
prove a commit is reproducible.

## Registry

Command-line refs resolve through the registry, in precedence order (low to
high): global flake registry (default `https://channels.nixos.org/flake-registry.json`),
system `/etc/nix/registry.json`, user `~/.config/nix/registry.json`,
`--override-flake`. Registries do **not** rewrite `inputs` declared in a
flake — those are resolved by the lock graph.

```bash
nix registry list
nix registry pin nixpkgs github:NixOS/nixpkgs/nixos-26.05   # freeze this machine's ref
nix registry add myflake github:org/repo
```

## Pure evaluation

Flakes default to pure mode: the result is determined by declared inputs;
`builtins.currentSystem`, `currentTime`, `nixPath`, and store-path access are
disabled. Mutable filesystem access exists only through declared path inputs.
`--impure` lifts this for a single command and should stay a debugging aid —
config that depends on `--impure` is not reproducible and will behave
differently in CI.

Pitfalls of purity:

- A git-backed flake cannot see untracked files; `git add` before evaluating.
- Relative path input literals must begin with `./` (otherwise the string is
  read as a registry reference) and must stay within the flake's tree.
- Environment variables used in evaluation are impure; pass configuration via
  `--arg`/`--override-input` or expose it as an input instead.

## Sources

- Nix manual, `nix flake` (all subcommands): https://nix.dev/manual/nix/stable/command-ref/new-cli/nix3-flake.html (accessed 2026-09-30)
- Nix manual, `nix3-flake-lock`, `nix3-flake-update`, `nix3-flake-metadata`, `nix3-registry`: same manual (accessed 2026-09-30)
- nix.dev, flakes concept: https://nix.dev/concepts/flakes (accessed 2026-09-30)
