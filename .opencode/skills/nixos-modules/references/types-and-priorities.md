# Option types, priorities, and ordering

## Priorities (numeric; lower wins)

| Expression | Priority | Meaning |
|---|---|---|
| `lib.mkForce v` | 50 | strongest; discards weaker definitions |
| plain definition `v` | 100 | normal module config |
| `lib.mkDefault v` | 1000 | weakest user definition; any plain definition overrides |
| `lib.mkOptionDefault v` | 1500 | an option's `default` value |

`lib.mkOverride n` sets an arbitrary priority. Only definitions with the
**lowest priority number present** survive; if several share it and the type is
unique, that is a conflict. Type `apply`/merge functions then combine the
survivors.

## Ordering (never discards; default 1000)

| Expression | Order | Effect |
|---|---|---|
| `lib.mkBefore v` | 500 | earlier in concatenation |
| default | 1000 | normal position |
| `lib.mkAfter v` | 1500 | later in concatenation |

Ordering matters for types that concatenate (`listOf`, `lines`, strings) and
is irrelevant for equal-value types (`bool`, `int`, `str`, `enum`, `path`).

## Common types

| Type | Merge semantics | Notes |
|---|---|---|
| `lib.types.bool` | equal or conflict | `boolByOr` ORs |
| `lib.types.int`, `float`, `str`, `enum [ … ]`, `path` | equal or conflict | use `enum` to constrain choices |
| `lib.types.listOf t` | concatenates | order via `mkBefore`/`mkAfter` |
| `lib.types.attrsOf t` | recursive attr merge | strict; `lazyAttrsOf` for mutually dependent attrs (but conditional definitions misbehave) |
| `lib.types.nullOr t` | null passes through | the standard "unset" wrapper |
| `lib.types.either t1 t2`, `oneOf [ … ]` | union | first matching check wins |
| `lib.types.package` | single definition, store-path check | `mkPackageOption` builds on it |
| `lib.types.lines` | concatenates newline-separated | used heavily by `environment.etc` etc. |
| `lib.types.attrs` | **avoid** | deprecated alias that silently drops earlier definitions and does not discharge `mkDefault`/`mkIf`; use `attrsOf anything` |
| `lib.types.uniq t` / `unique` | errors on second definition | for genuinely single-owner options |

Other useful pieces:

- `types.submodule { options = { … }; }` — nested options; equivalent to
  `submoduleWith { shorthandOnlyDefinesConfig = true; }`.
- `types.submoduleWith { modules; specialArgs; class; }` — submodule needing
  its own arguments/class.
- A submodule may have defaults yet still needs an outer default (usually
  `{ }`) to be optional.
- `mkOptionType { name; check; merge; }` for custom types; `addCheck` narrows
  an existing type.

## Error shapes

- Conflict: `The option 'X' has conflicting definition values:` then one
  `- In 'file': value` line per definition, and the suggestion to use
  `lib.mkForce` or `lib.mkDefault`. The listed files are the two definitions
  to reconcile.
- Unique violation: `The option 'X' is defined multiple times while it's
  expected to be unique.`
- Type mismatch: `A definition for option 'X' is not of type 'string'.
  Definition values: …` (newer v2 merge types prefix `TypeError:`).
- Missing option: `The option 'X' does not exist. … Did you mean …?` — a
  declaration is missing (typo, wrong namespace, module not imported).
- Missing value: `The option 'X' was accessed but has no value defined.`

## Worked example: choosing priorities

A base module sets a default, a host overrides it, and a service forces a
requirement:

```nix
# base module (weakest)
networking.firewall.allowedTCPPorts = lib.mkDefault [ 22 ];

# host file (normal strength — overrides the default list? no: lists concatenate)
networking.firewall.allowedTCPPorts = [ 80 ];
# result: [ 22 80 ] — concatenation, not override

# a module that must win outright
networking.firewall.allowedTCPPorts = lib.mkForce [ 443 ];
# result: [ 443 ] — all weaker definitions discarded
```

Lists merge by concatenation, so `mkForce` is the tool for replacement;
`mkDefault` is the tool for "overridable suggestion" on scalar types. Pair
`mkBefore`/`mkAfter` with concatenating types when order matters.

## Sources

- NixOS manual, option types and priorities: https://nixos.org/manual/nixos/stable/#sec-option-types and #sec-option-definitions (accessed 2026-09-30)
- nixpkgs `lib/options.nix`, `lib/types.nix` (raw source): https://github.com/NixOS/nixpkgs (accessed 2026-09-30)
