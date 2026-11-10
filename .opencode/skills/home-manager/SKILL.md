---
name: home-manager
description: Configure user environments with Home Manager, standalone or as a NixOS module — `home.nix`, `home-manager switch`, flake integration. Use when editing Home Manager configuration or debugging its activation.
---

# Home Manager

Home Manager declaratively configures a user's packages and dotfiles. On
NixOS, decide first **how it is integrated**: as a NixOS module (system
manages users and pkgs; preferred on NixOS) or standalone (Home Manager has
its own `pkgs`, used on non-NixOS machines or for independent user setups).

## Workflow

1. **Choose the integration.** NixOS-managed:
   `home-manager.nixosModules.home-manager` plus `home-manager.useGlobalPkgs =
   true` and `home-manager.useUserPackages = true`. Standalone:
   `home-manager.lib.homeManagerConfiguration { pkgs; modules; }` and the
   `home-manager switch --flake .#user@host` command. Done when one owner
   exists for the user's environment.
2. **Match versions.** The Home Manager branch must match the nixpkgs branch:
   `release-26.05` with NixOS 26.05, `master` with unstable. Done when no
   version-mismatch warning appears.
3. **Write the user module(s)** — `home.username`, `home.homeDirectory`, and
   `home.stateVersion` (set once at first adoption, never changed), then
   `programs.*`/`services.*`/`home.packages`.
4. **Wire shared context.** `home-manager.extraSpecialArgs` (or
   `extraSpecialArgs` standalone) to pass flake `inputs` into Home Manager
   modules; `home-manager.sharedModules` for settings every user should get.
5. **Apply.** NixOS-managed: `nixos-rebuild switch` (Home Manager runs in
   activation). Standalone: `home-manager switch --flake .#user@host`. Done
   when the activation service reports success.
6. **Verify by observation.** Check the generated file exists
   (`~/.config/...`), the program starts, and the activation service status is
   clean: `systemctl status home-manager-$USER` (system service) or
   `systemctl --user status home-manager.service`.

## NixOS-module integration skeleton

```nix
{
  home-manager = {
    useGlobalPkgs = true;      # reuse the system pkgs — no second nixpkgs
    useUserPackages = true;    # install into /etc/profiles/per-user/<user>
    extraSpecialArgs = { inherit inputs; };
    users.alice = ./home/alice.nix;
  };
}
```

- `useGlobalPkgs` matters because without it Home Manager evaluates its own
  nixpkgs: system overlays and `config` do **not** apply to the user's
  packages.
- `useUserPackages` is required if you use `nixos-rebuild build-vm` — the VM
  cannot reach per-user profiles otherwise.

## Modules and arguments

Home Manager modules take `{ config, lib, pkgs, osConfig, ... }` (plus
`home.username`, `home.homeDirectory`, `home.stateVersion` as options).
`osConfig` (alias `nixosConfig`) exposes the NixOS configuration when running
as a NixOS module — use it to avoid setting something in both places.

A faithful pattern for user-scoped state is to keep Home Manager for
*browseable user config* and the system for daemons/security. Don't manage the
same file from both (systemd unit vs `home.file`) — one writer.

## Pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| "Nixpkgs version mismatch" warning | Home Manager branch ≠ nixpkgs branch | align `release-XX.YY` / `master` |
| packages missing from `PATH` in a shell | shell not sourcing `hm-session-vars.sh` | add the HM shell integration for that shell, or log out/in |
| overlays ignored in user packages | not using `useGlobalPkgs` | enable it (or intentionally maintain HM's own pkgs) |
| file conflicts at activation | HM `home.file` and a NixOS module both write the same path | pick one owner |
| activation failed: user service not running | inspected as root or wrong service name | `systemctl status home-manager-$USER`, or `--user` for `startAsUserService` |
| user changed a password-less login after switch | Home Manager managing the account while NixOS does too | leave account options to NixOS `users.users` |
| impermanence has no effect on home files | HM persistence module requires the HM NixOS module | add both modules; see `nixos-hosts` impermanence reference |

## References

None — this skill is self-contained. For system-level user/secret matters see
`nixos-secrets`; for persistence see `nixos-hosts`.

## Sources

- Home Manager manual, NixOS module and flake installation: https://nix-community.github.io/home-manager/ (accessed 2026-09-30)
- Home Manager, upgrading and `stateVersion`: https://nix-community.github.io/home-manager/usage/upgrading.html (accessed 2026-09-30)
- impermanence + Home Manager notes: https://github.com/nix-community/impermanence (accessed 2026-09-30)
