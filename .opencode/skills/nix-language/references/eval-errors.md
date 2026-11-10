# Evaluation error catalogue

Read traces bottom-up and match the message below. Cross-references name the
skill that owns the fix.

## Reading a trace

- Re-run with `--show-trace`; without it Nix prints only the outermost frame
  and the note `use '--show-trace' to show the full trace`.
- The **last frames** name the file and attribute doing the failing work; the
  first frames are just the entry point (`nixos-rebuild`, `nix build`).
- `while evaluating the attribute '…'` lines are breadcrumbs down the call
  chain; the deepest one is the culprit.
- `error: … at /nix/store/…-source/file.nix:12:34` — the store path tells you
  which input owns the code (yours vs nixpkgs vs a dependency).

## Syntax and resolution

| Message (shape) | Meaning | Fix |
|---|---|---|
| `syntax error, unexpected '…'` with `«string»:LINE:COL` | parser stopped at a token | fix the construct at that position; since Nix 2.34 tokens are legible (`unexpected CONCAT`-style names are gone) |
| `undefined variable 'x'` | name not in scope | check spelling, `let` binding, or `rec`/`inherit`; function arguments arrive via the header |
| `attribute 'foo' missing` (often `Did you mean 'for'?`) | selection on an attrset without that key | `x or default`, `?`, correct the path |
| `attempt to select an attribute from a non-set` | `.a` applied to a list/string | `typeOf` the value, fix the producer |

## Types and coercion

| Message (shape) | Meaning | Fix |
|---|---|---|
| `expected a set but found …` / `expected a list but found …` / `expected a Boolean but found …` | value has the wrong type for the operation | inspect with `typeOf`; convert explicitly (`toString`, `"${…}"`) |
| `cannot coerce an integer to a string` | implicit conversion attempted | `toString n` or `"${toString n}"` |
| `value is a string while a set was expected` on `//`/`//`-style merges | one operand is not an attrset | check both sides |

## Functions

| Message (shape) | Meaning | Fix |
|---|---|---|
| `attempt to call something which is not a function but a set: { … }` | called a non-function, often a module (`import ./x.nix` vs `import ./x.nix { }`) | call or import as intended |
| `function 'anonymous lambda' called without required argument 'x'` | missing attr in the call set | supply it, or give the argument a default (`x ? …`) |
| `… called with unexpected argument 'y'` | extra attr in the call set | add `…` to the function pattern or remove the argument; Lix 2.93+ lists all missing and unexpected arguments at once |
| `infinite recursion encountered` | a value depends on itself | break the cycle: function, lazy attr, `mkIf`, or defer the transformation (see `nix-language` main file) |
| `stack overflow; max-call-depth exceeded` | unbounded recursion depth (setting `max-call-depth`, default 10000) | turn the recursion into iteration or a fold; this is distinct from a value cycle |

## Module-system errors

Full treatment lives in `nixos-modules`; the common ones you will diagnose
from an evaluation failure:

| Message (shape) | Meaning |
|---|---|
| `The option 'x' does not exist. Definition values: … Did you mean …?` | a module defines an option never declared; typo or missing import |
| `The option 'x' was accessed but has no value defined. Try setting the option.` | read a `config.x` with no default and no definition |
| `The option 'x' has conflicting definition values` | two equal-priority definitions of a unique type; use `lib.mkDefault`/`lib.mkForce` |
| `A definition for option 'x' is not of type 'string'. Definition values: …` | value fails the declared type's `check`; newer merge types prefix `TypeError:` |
| `The option 'x' is defined multiple times while it's expected to be unique` | unique type (e.g. `package`) defined twice |
| `infinite recursion encountered` during `nixos-rebuild` | often `config` referenced inside `imports`, or an `attrsOf`/`filterAttrs` cycle — see `nixos-modules` |

## Lix and version notes

- Lix 2.93+ improves function-call argument errors and prints derivation
  summaries in stack traces; Lix 2.95 adds `builtins.warn`.
- Pipe operators (`|>`, `<|`) exist upstream from 2.24 but remain an
  experimental feature; if a file uses them and fails to parse, the feature is
  probably not enabled. Lix names it `pipe-operator` (singular).
- `nix-instantiate --eval` is lazy: nested values print as `<CODE>`-style
  thunks unless you pass `--strict` (or use `nix eval`).

## Sources

- Nix manual, language and evaluation: https://nix.dev/manual/nix/stable/language/ (accessed 2026-09-30)
- Nixpkgs manual, module system error semantics: https://nixos.org/manual/nixpkgs/stable/#sec-writing-modules (accessed 2026-09-30)
- Lix release notes (2.93–2.95): https://docs.lix.systems/manual/lix/stable/release-notes/ (accessed 2026-09-30)
