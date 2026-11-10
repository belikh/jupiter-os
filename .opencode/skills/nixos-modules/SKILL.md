---
name: nixos-modules
description: Write and compose NixOS modules — options, `mkOption`/`mkIf`/`mkMerge`, types, priorities, imports, `specialArgs`. Use when adding an option, extending system configuration, or fixing module merge and conflict errors.
---

# NixOS modules

A module is a function returning `{ imports; options; config; }`. Writing one
well is about **declaring** the smallest interface the configuration needs
(`options`) and **defining** behaviour lazily (`config` guarded by `mkIf`).
Reach for an existing option before writing a module.

## Workflow

1. **Search before inventing.** Check whether nixpkgs already ships the option
   (`search.nixos.org/options`, `nixos-option <path>`, the "Declared by" link on
   an option page). Done when you can name the option you will use, or state
   that none exists.
2. **Choose the extension point.** Existing option to set → define it in the
   host/module. New cross-cutting behaviour → a new module under the repo's
   convention; per-host one-offs → the host file. Done when you know which
   file owns the change.
3. **Declare options** in the house style: `options.<ns>.<name> =
   lib.mkOption { type; default; description; example; }`, or `mkEnableOption`
   for a toggle, or `mkPackageOption` for a package. Done when every option has
   a type and description.
4. **Define config lazily**: `config = lib.mkIf cfg.enable { … };` with the
   `cfg = config.<ns>` binding in a `let`. Use `mkMerge`/`optionals` rather than
   a top-level `if`. Done when disabling the option yields an empty config.
5. **Wire arguments deliberately.** `specialArgs` for values needed in
   `imports`; `_module.args` for values needed only in module bodies. Done when
   no `config` reference appears inside `imports`.
6. **Evaluate.** `nix flake check --no-build` (or `nixos-rebuild build`) and
   read any conflict/type error against `references/types-and-priorities.md`.
   Done when evaluation passes and `nixos-option` shows the values you expect.

## Module anatomy

```nix
{ config, lib, pkgs, ... }:

let
  cfg = config.my.service;
in
{
  options.my.service = {
    enable = lib.mkEnableOption "my service";       # bool, default false
    package = lib.mkPackageOption pkgs "mytool" { }; # defaults to pkgs.mytool
    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { port = "8080"; };
      description = "Extra settings passed to the service.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.my-service = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${cfg.package}/bin/mytool";
      environment = cfg.settings;
    };
  };
}
```

- **`mkIf` matters.** References to `config` inside a plain top-level `if` are
  evaluated eagerly; `mkIf` pushes the condition down into every definition so
  conditions can depend on `config` without recursion. nixpkgs documents this
  as "delaying conditionals".
- **`imports` evaluates before the fixpoint.** Referencing `config` in an
  import list is the standard route to `infinite recursion encountered` —
  import unconditionally and gate the effects with `mkIf`.
- **`mkMerge [ … ]`** combines several config sets (use with `optionals` for
  conditional fragments); per-attribute priorities survive the merge.
- **`config.lib`** (`attrsOf attrs`) is the supported place for helper
  functions/constants a module exposes to others.
- **Assertions beat silent breakage:** `assertions = [ { assertion = …;
  message = "…"; } ];` and `warnings = [ … ];`.

## `specialArgs` vs `_module.args`

| Mechanism | Visible where | Use for |
|---|---|---|
| `specialArgs` (on `nixosSystem`) | module **arguments**, including in `imports` | external values every module may need (e.g. flake `inputs`) |
| `_module.args` (an option) | module arguments in bodies and submodules | values that depend on the fixpoint, or per-class args |
| `extraModules` | prepended module list, lower priority than `modules` | injecting a base module without overriding user definitions |

Do **not** pass `lib` through `specialArgs` to inject helpers; add a named
attribute (e.g. `specialArgs.myLib = …`) and let `lib` stay the real library.
Submodules do not inherit `_module.args` unless passed explicitly (except
`name`); use `types.submoduleWith` when they need their own `specialArgs`.
`extraModules`/`modules` on `nixosSystem` are the composition seam; `system`
and `pkgs` arguments are legacy (host platform comes from the configuration).

## Prioritising and ordering

Short version; the full table is in `references/types-and-priorities.md`:

- Equal-priority definitions of a unique type **conflict**; fix with
  `lib.mkDefault` (weaker, priority 1000) or `lib.mkForce` (stronger, 50).
- Normal definitions sit at 100; option defaults at 1500.
- Ordering (`mkBefore`/`mkAfter`) never excludes a definition — it only orders
  list/string concatenation.

## Pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `The option 'x' does not exist` | definition without declaration, typo, or missing import | declare the option, or import the module that does |
| `conflicting definition values` | two equal-priority definitions | decide the winner: `mkDefault` on the general, plain on the specific (or `mkForce`) |
| `accessed but has no value defined` | option read with no default | give it a default, or define it |
| `infinite recursion` under a module | `config` used in `imports`, or an attrset consumed while building | move the use into `config`, defer with `mkIf` |
| `if` at module top level behaves oddly under disabling | eager conditional defeated lazy merging | use `mkIf` |
| submodule options rejected | shorthand config without `shorthandOnlyDefinesConfig`, or missing outer default | use `types.submodule { options = …; }` and give the option a default like `{ }` |
| option appears nowhere in docs | module not imported by any host | import it, or accept it is dead code |

## References

- `references/types-and-priorities.md` — the type catalogue, exact priority
  numbers, merge semantics, and error shapes; read when choosing a type or
  resolving a merge conflict.

## Sources

- Nixpkgs manual, module system: https://nixos.org/manual/nixpkgs/stable/#module-system (accessed 2026-09-30)
- NixOS manual, writing modules, delaying conditionals, option types: https://nixos.org/manual/nixos/stable/#sec-writing-modules (accessed 2026-09-30)
- Option search and "Declared by" evidence: https://search.nixos.org/options (accessed 2026-09-30)
- `nixos-option`: https://nixos.org/manual/nixos/stable/#sec-nixos-option (accessed 2026-09-30)
