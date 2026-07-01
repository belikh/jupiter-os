# Generates a CommonMark options reference for every `jupiter.*` module option,
# via `pkgs.nixosOptionsDoc` (nixos-render-docs) — the source of truth backing
# `docs/module-options.md` (see `make docs-modules`), so the option tables in
# docs/04-modules-reference.md's per-module prose stay generated rather than
# hand-transcribed and prone to drifting from the actual `mkOption` decls.
#
# Evaluates a synthetic NixOS system importing every module file that declares
# `jupiter.*` options, plus the same flake-injected modules `mkHost` gives real
# hosts (disko, impermanence, jovian, chaotic, home-manager, ha-linux-agent,
# sops) so unconditional `config` blocks (e.g. n8n.nix, backups.nix) resolve
# against real option declarations instead of failing as "unmatched". No host
# actually enables any `jupiter.*` toggle here, so none of the guarded `config
# = lib.mkIf cfg.enable { ... }` bodies run — this only needs the `options`
# declarations to be valid, not a buildable system.
{
  lib,
  pkgs,
  nixpkgsLib, # nixpkgs.lib from the flake input (for `nixosSystem`)
  sopsNixModule,
  impermanenceModule,
  diskoModule,
  jovianModule,
  chaoticModule,
  homeManagerModule,
  haLinuxAgentModule,
}:
let
  root = ../.;
  rootStr = toString root + "/";

  jupiterModuleFiles = [
    (root + "/modules/core/impermanence.nix")
    (root + "/modules/core/scheduler.nix")
    (root + "/modules/core/branding.nix")
    (root + "/modules/desktop/default.nix")
    (root + "/modules/desktop/dashboard-kiosk.nix")
    (root + "/modules/desktop/dashboard-gaming.nix")
    (root + "/modules/gaming/console.nix")
    (root + "/modules/network/dns.nix")
    (root + "/modules/network/nas-bond.nix")
    (root + "/modules/network/pxe-server.nix")
    (root + "/modules/services/backups.nix")
    (root + "/modules/services/ha-agent.nix")
    (root + "/modules/services/loki.nix")
    (root + "/modules/services/mqtt.nix")
    (root + "/modules/services/n8n.nix")
    (root + "/modules/services/postgresql.nix")
    (root + "/modules/services/state-backup.nix")
    (root + "/modules/services/syncthing.nix")
    (root + "/modules/storage/backup.nix")
    (root + "/modules/storage/iscsi.nix")
    (root + "/modules/storage/replication.nix")
    (root + "/modules/storage/smart-monitoring.nix")
    (root + "/modules/storage/zfs-profiles.nix")
    (root + "/modules/home/default.nix")
  ];

  eval = nixpkgsLib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      sopsNixModule
      impermanenceModule
      diskoModule
      jovianModule
      chaoticModule
      homeManagerModule
      haLinuxAgentModule
      { system.stateVersion = "26.05"; }
    ]
    ++ jupiterModuleFiles;
  };

  # Render "declared by" as a plain repo-relative path (e.g.
  # `modules/storage/backup.nix`) instead of nixos-render-docs' default
  # assumption that any non-absolute declaration lives in the nixpkgs tree
  # (which would otherwise link to github.com/NixOS/nixpkgs).
  transformOptions =
    opt:
    opt
    // {
      declarations = map (
        decl:
        let
          s = toString decl;
        in
        {
          name = if lib.hasPrefix rootStr s then lib.removePrefix rootStr s else s;
        }
      ) opt.declarations;
    };
in
pkgs.nixosOptionsDoc {
  options = { inherit (eval.options) jupiter; };
  inherit transformOptions;
  # Missing descriptions should fail CI (make docs-modules-check), not just warn.
  warningsAreErrors = true;
}
