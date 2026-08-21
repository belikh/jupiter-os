# PostgreSQL server — the fleet's SQL database service.
#
# Network scope (v2, 2026-08-22): this is a FLEET database, not a private
# one. With `openFirewall` (default true) postgres listens on all interfaces
# (`enableTCPIP = true`) and the firewall opens :5432 for the trusted home
# LAN — the same trust model as mosquitto and NFS. Auth from the LAN is
# scram-sha-256 only, and no role has a password yet, so every network
# connection fails authentication until a consumer is provisioned: exposure
# here means REACHABILITY, not access. Bring consumers up through this
# wrapper (ensureDatabases/ensureUsers pass-throughs with sops-sourced
# passwordFiles) rather than inlining services.postgresql in a host file.
# `openFirewall = false` returns to loopback-only upstream defaults.
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

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Serve the fleet: listen on all interfaces and open :5432 in the
        firewall for the trusted LAN (jupiter.fleet.lanCidr). LAN logins are
        scram-sha-256 only — roles without a password cannot connect.
      '';
    };

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
      enableTCPIP = lib.mkIf cfg.openFirewall true;
      # pg_hba: our rules merge ABOVE upstream's defaults (first match
      # wins), so fleet-LAN TCP logins hit this scram rule and localhost
      # keeps upstream's md5 defaults. No passworded role exists yet — these
      # lines reject every LAN login until one is provisioned. Deliberate.
      authentication = lib.mkIf cfg.openFirewall ''
        # Fleet LAN (jupiter.fleet.lanCidr) — scram passwords only, never trust.
        host all all ${config.jupiter.fleet.lanCidr} scram-sha-256
      '';
      # dataDir stays upstream-default (/var/lib/postgresql/<major>). On
      # callisto this lands on the iSCSI-root ext4 (europa's
      # tank/services/callisto-root zvol) — same durability envelope as the
      # whole host, so europa being down takes the database down with
      # everything else here.
    };

    # House pattern (cf. modules/services/mqtt.nix): the trusted-LAN port is
    # opened plainly; per-source policing beyond the LAN belongs to the UDM.
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ 5432 ];
  };
}
