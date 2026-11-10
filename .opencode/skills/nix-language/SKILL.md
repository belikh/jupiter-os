---
name: nix-language
description: Read, write, and debug Nix expressions — syntax, laziness, `lib` functions, `nix eval` and `nix repl`. Use when editing a `.nix` expression, or hitting infinite recursion, type errors, or unexpected evaluation results.
---

# Nix language and evaluation

Nix is a lazy, pure, functional language. Evaluation errors are normal feedback,
not disasters. The reliable loop: reproduce the evaluation deterministically,
narrow to the smallest failing expression, inspect it, fix, re-evaluate the same
command.

## Workflow

1. **Find the entry point.** Identify the exact expression being evaluated —
   `nix eval -f file.nix some.attr`, `nix eval .#attr`, or the failing
   `nixos-rebuild`/`nix build`. Done when one command shows the value or error.
2. **Reproduce in isolation.** Narrow to the smallest attribute path that
   fails. `nix repl` with `:lf`, `:l`, `:p`, `:doc` avoids rebuilding anything.
   Done when the failure reproduces without a full system evaluation.
3. **Get a trace.** Re-run with `--show-trace` and read it bottom-up: the
   innermost frames name the file and attribute that actually failed, not the
   entry point that reported it.
4. **Classify the error** against `references/eval-errors.md`. Nearly all are
   one of: infinite recursion, a missing attribute, a type mismatch, or an
   undefined variable.
5. **Fix and re-run the step-1 command.** Done when the original command
   evaluates; if the expression feeds a build, continue in `nix-packaging` or
   `nixos-debugging`.

## Language essentials

- **Laziness is call-by-need.** Nothing is forced until needed; `let` bindings
  and function arguments are memoised. Unused attributes can hold broken
  expressions without failing — which is why `mkIf` can reference `config`
  without recursion.
- **`let … in` bindings are mutually recursive**, and `rec { … }` puts
  attribute names in scope. Self-reference in either is the classic
  `infinite recursion encountered`.
- **`//` merges shallowly.** `{ a.b = 1; } // { a.c = 2; }` replaces `a`
  wholesale. For deep merges use `lib.recursiveUpdate`.
- **`builtins` are evaluator primitives** (`import`, `toString`, `toJSON`,
  `readFile`), while **`lib` is nixpkgs' pure-Nix library** (`mapAttrs`,
  `mkIf`, `types`). In a NixOS module, `lib` arrives as a module argument.
- **Attrsets are the core idiom.** Modules, packages, and config are all
  attrsets; most Nix work is composing attrsets without introducing cycles.
- **Paths need a slash** (`./foo`, `../bar`); a bare word is an identifier.
  Interpolating a path (`"${./foo}"`) copies it into the store.
- **Pipes `|>` and `<|`** (2.24+) reorder calls (`a |> f` is `f a`) but are
  still an experimental feature upstream, and Lix spells the feature
  `pipe-operator`. Prefer ordinary application unless the flake enables them.

## Debugging commands

```bash
nix eval --expr '1 + 1'                        # evaluate a literal expression
nix eval -f ./file.nix some.attr               # evaluate an attribute
nix eval .#pkg.version --raw                   # flake output, raw string
nix eval -f ./file.nix some.attr --show-trace   # full evaluation trace
nix-instantiate --eval --strict ./file.nix      # force nested values
nix repl                                        # :lf . , :l file , :p expr , :doc lib.mapAttrs
lib.debug.traceSeq value                        # deep trace; traceSeqN bounds depth
builtins.typeOf value                           # "int" | "string" | "set" | "lambda" | ...
```

Prefer `lib.debug.traceVal`/`lib.debug.traceSeq` over `builtins.trace`
(shallow). `traceSeq` can itself recurse forever on cyclic values — use
`traceSeqN` when in doubt. `nix repl`'s `:doc` renders nixpkgs doc comments
for any `lib` function, which beats guessing at signatures.

## Pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `infinite recursion encountered` | a value depends on itself: `let x = x;`, `rec` self-reference, an attrset consumed before it is produced | break the cycle — make it a function, guard with `mkIf`, defer the offending `filterAttrs`/`mapAttrs` |
| `attribute 'x' missing` | typo or wrong path | `x or default`, `?`, and `nix repl` tab completion |
| `expected a set but found …` | selecting `.a` on a non-attrset | check with `typeOf`, fix the producer |
| `cannot coerce …` | mixing strings, numbers, paths | explicit `toString` / `"${…}"` |
| not-strict output (`<CODE>`-looking thunks) | `nix-instantiate --eval` without `--strict` | add `--strict`, or use `nix eval` |
| works under `nix eval` but not in a flake | flake purity / untracked files | see `nix-flakes` |

## References

- `references/lib-toolkit.md` — the `lib` functions worth knowing, by area,
  with signatures; read before writing non-trivial attrset transformations.
- `references/eval-errors.md` — error-message catalogue: exact wording,
  meaning, standard fix; read when step 4 lands on an unfamiliar message.

## Sources

- Nix language overview: https://nix.dev/manual/nix/stable/language/ (accessed 2026-09-30)
- Operators, laziness, string context: https://nix.dev/manual/nix/stable/language/operators.html (accessed 2026-09-30)
- `nix eval`, `nix repl`: https://nix.dev/manual/nix/stable/command-ref/new-cli/nix3-eval.html and …/nix3-repl.html (accessed 2026-09-30)
- nixpkgs `lib` reference: https://nixos.org/manual/nixpkgs/stable/#chap-functions (accessed 2026-09-30)
