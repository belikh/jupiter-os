# `lib` toolkit

The nixpkgs library functions an agent actually reaches for. Signatures are
Nix-style (`f : arg : result`); `:doc lib.<name>` in `nix repl` renders the
authoritative doc comment for any of these. Module helpers (`mkIf`, `mkMerge`,
`mkDefault`) are covered in the `nixos-modules` skill, not here.

## Attribute sets

| Function | Signature | Use |
|---|---|---|
| `mapAttrs` | `(name: value: x) -> attrs -> attrs` | transform every value; names preserved |
| `mapAttrsToList` | `(name: value: x) -> attrs -> list` | keep the names by folding them into the result |
| `filterAttrs` | `(name: value: bool) -> attrs -> attrs` | keep matching attrs; can cause infinite recursion if used before the set is produced — call it late |
| `optionalAttrs` | `cond -> attrs -> attrs` | `{ }` or the attrs, chosen by a condition |
| `genAttrs` | `names -> (name: value) -> attrs` | build a set keyed by a name list |
| `catAttrs` | `name -> listOfAttrs -> list` | collect one attribute from many sets |
| `attrByPath` | `path -> default -> attrs -> value` | deep lookup with a fallback |
| `hasAttrByPath` | `path -> attrs -> bool` | deep existence test |
| `recursiveUpdate` | `attrs -> attrs -> attrs` | deep merge; left is overridden where types differ (unlike `//`) |
| `zipAttrsWith` | `(name: values: x) -> listOfAttrs -> attrs` | combine values sharing a name |
| `mergeAttrs` | `attrs -> attrs -> attrs` | shallow merge (like `//`, as a function) |

## Lists

| Function | Signature | Use |
|---|---|---|
| `optional` | `bool -> value -> list` | one-or-zero element |
| `optionals` | `bool -> list -> list` | list-or-empty (the workhorse for conditional config) |
| `singleton` | `value -> list` | one-element list |
| `concatMap` | `(a -> list) -> list -> list` | map-then-flatten, one step |
| `flatten` | `list -> list` | flatten one level |
| `unique` | `list -> list` | deduplicate (O(n²); fine for config-sized inputs) |
| `sort` | `(a -> a -> bool) -> list -> list` | explicit comparator sort |
| `take` / `drop` | `int -> list -> list` | slice |
| `last` / `head` / `elemAt` | … | prefer pattern matching where possible |
| `foldl'` | `(acc: x: acc) -> init -> list -> acc` | strict fold; use this over `foldl` in config code |

## Strings

| Function | Signature | Use |
|---|---|---|
| `concatStringsSep` | `string -> listOfStrings -> string` | join (alias `join`) |
| `concatMapStringsSep` | `string -> (a -> string) -> list -> string` | map to strings then join |
| `optionalString` | `bool -> string -> string` | string-or-empty |
| `hasPrefix` / `hasSuffix` | `string -> string -> bool` | tests |
| `splitString` | `string -> string -> listOfStrings` | split on a separator |
| `replaceStrings` | `listOfFrom -> listOfTo -> string -> string` | literal replacements |
| `toJSON` / `fromJSON` | `value -> string` / `string -> value` | data interchange; `fromJSON` is a builtin |
| `escapeShellArg` / `escapeShellArgs` | `string -> string` | shell quoting for generated scripts |
| `makeBinPath` | `listOfPackages -> string` | colon-joined `bin` dirs for wrappers |

## Paths and files

| Function | Use |
|---|---|
| `toFile` | write a string to the store as a file (name, text) |
| `importJSON` | read a JSON file at evaluation time |
| `cleanSource` / `cleanSourceWith` | filter source trees before use as `src` |
| `sourceByRegex` / `sourceFilesBySuffices` | source filters for derivations (see `nix-packaging`) |
| `types.path` | option type for paths (see `nixos-modules`) |

## Debugging

| Function | Use |
|---|---|
| `lib.debug.traceVal` | trace a value shallowly |
| `lib.debug.traceSeq` | trace a value deeply (can recurse forever on cycles) |
| `lib.debug.traceSeqN` | depth-limited deep trace — prefer when unsure |
| `lib.debug.traceValFn` | transform a value while tracing it |
| `lib.debug.traceIf` | trace only when a condition holds |

## Functional fixtures

- `lib.id`, `lib.const`, `lib.flip`, `lib.pipe value [ f g h ]` — composition
  helpers; `pipe` (library) is unrelated to the `|>` operator.
- `lib.fix (self: …)` — tie a recursive knot explicitly where `rec` is
  undesirable.
- `lib.fix'` — `fix` variant taking the function and the argument together.

## Conventions

- **Laziness is not optional.** `filterAttrs` and `mapAttrs` over an attrset
  that is still being built (e.g. `config` in a module) is a standard source
  of `infinite recursion encountered`; structure code so the input is produced
  before the transformation runs.
- **Prefer `optionals`/`optionalAttrs` over `if` at the top of config** — they
  compose with `mkIf` and nesting; `if` evaluated eagerly at the module top
  level can break conditional deferral (see `nixos-modules`).
- **Check the source of truth.** All of these are documented in the nixpkgs
  manual, "Functions reference": https://nixos.org/manual/nixpkgs/stable/#chap-functions
  (accessed 2026-09-30), and by `:doc` in `nix repl`.
