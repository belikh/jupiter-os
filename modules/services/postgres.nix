# PostgreSQL server — the fleet's SQL database service.
#
# Deliberately minimal v1: upstream defaults give an off-host-unreachable
# instance with peer authentication for local users — `enableTCPIP` is false,
# so postgres binds only loopback TCP :5432 (md5 rules that are unusable
# until some role is given a password) plus the unix socket at
# /run/postgresql (peer auth); no firewall port anywhere. That needs NO
# password secret at all — the `postgres` superuser is reachable only by
# root/`postgres` on this host. When a real consumer appears, extend this
# wrapper (ensureDatabases/ensureUsers pass-throughs, sops-sourced password
# files, enableTCPIP + firewall) rather than inlining services.postgresql in
# a host file.
#
# Package policy — depends on how the consuming host is built:
#   - Untuned host (substitutes from cache.nixos.org): keep the STOCK
#     derivation. A substituted package never runs its check phases locally,
#     so nothing needs silencing — and any overrideAttrs would change the
#     output hash and force a pointless local build.
#   - Microarch-tuned host (jupiter.build.microarch set — callisto and the
#     kiosks today): NOTHING substitutes from cache.nixos.org (every path is
#     gccarch-tagged); the closure comes from Harmonia instead. If Harmonia
#     doesn't carry a postgres build (it doesn't — no fleet consumer yet),
#     enabling this service forces a local build either way, and postgresql's
#     installCheckPhase (its initdb-based regression self-test) is confirmed
#     to fail in callisto's build sandbox (hosts/europa/configuration.nix,
#     live finding 2026-08-07). In that case silence doCheck/doInstallCheck
#     HOST-LOCALLY on the consumer (europa and callisto both do exactly
#     this) — never in a shared overlay, and never as a blanket rule.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.jupiter.services.postgres;
in
{
  options.jupiter.services.postgres = {
    enable = lib.mkEnableOption "PostgreSQL server";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.postgresql_17;
      defaultText = lib.literalExpression "pkgs.postgresql_17";
      description = ''
        PostgreSQL package. Keep the stock nixpkgs derivation (see the
        header comment: any overrideAttrs changes the hash and forces a
        local build whose installCheckPhase is known broken on callisto's
        sandbox).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.postgresql = {
      enable = true;
      package = cfg.package;
      # Upstream defaults kept deliberately:
      #   - enableTCPIP = false → unix socket only (/run/postgresql),
      #     peer auth; nothing reachable over the network.
      #   - dataDir = /var/lib/postgresql/<major>. On callisto this lands
      #     on the iSCSI-root ext4 (europa's tank/services/callisto-root
      #     zvol) — same durability envelope as the whole host, so europa
      #     being down takes the database down with everything else here.
    };
  };
}
