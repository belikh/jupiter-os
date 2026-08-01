{
  config,
  lib,
  ...
}:

# Subscribe every host in the fleet to the Harmonia binary cache served from
# europa's own /nix/store (services.harmonia on europa, see
# hosts/europa/configuration.nix). Replaces the former attic-substituter after
# the Attic decommission (issue #63): Harmonia is read-only and serves the live
# store, so there is no per-cache URL path (unlike Attic's /jupiter-os segment)
# — the cache root IS the host:port.
#
# europa is both server and consumer — for it, the loopback URL avoids a network
# roundtrip. Every other host reaches the same harmonia over the LAN at europa's
# reserved IP (10.1.1.2 — UniFi DHCP reservation). CI runners (GitHub Actions)
# reach it over the UDM WireGuard road-warrior, also at 10.1.1.2:5000.
#
# The public key is minted once via `nix-store --generate-binary-cache-key`
# (see docs/ci-harmonia-push-runbook.md) and is a PUBLIC value — it ships here
# as a placeholder until that keygen runs, then is replaced in place. A wrong
# placeholder is harmless: nix simply won't verify Harmonia's narinfos yet and
# falls back to cache.nixos.org.

let
  cfg = config.jupiter.core.harmoniaSubstituter;
  isHarmoniaServer = config.services.harmonia.cache.enable or false;
  host = if isHarmoniaServer then "localhost" else cfg.serverIp;
  url = "http://${host}:${toString cfg.port}";
in
{
  options.jupiter.core.harmoniaSubstituter = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Subscribe this host to europa's Harmonia binary cache ahead of
        cache.nixos.org. Default-on for every fleet host: once populated by CI
        (or the build server), Harmonia is the source for closures that are
        expensive to rebuild and any gccarch-tagged paths.
      '';
    };

    serverIp = lib.mkOption {
      type = lib.types.str;
      default = "10.1.1.2";
      description = ''
        europa's LAN IP — every host but europa itself reaches harmonia here.
        Ignored on europa (jupiter.services.harmonia / services.harmonia.enable
        true), which uses localhost instead.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5000;
      description = "Port harmonia listens on (matches europa's services.harmonia.settings).";
    };

    publicKey = lib.mkOption {
      type = lib.types.str;
      default = "jupiter-cache-1:REPLACE-ME-generate-via-nix-store---generate-binary-cache-key=";
      description = ''
        Harmonia cache public key. Minted once on europa via:
          nix-store --generate-binary-cache-key jupiter-cache-1 \
            /var/lib/secrets/harmonia.secret /var/lib/secrets/harmonia.pub
        Paste the contents of harmonia.pub here (a public value) once
        generated — see docs/ci-harmonia-push-runbook.md. The placeholder
        default keeps evaluation green; nix just won't trust Harmonia paths
        until it's replaced.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    nix.settings = {
      substituters = [ url ];
      trusted-public-keys = [ cfg.publicKey ];
      # Fail fast if Harmonia is unreachable (e.g. a PR-side CI run that
      # hasn't brought up the WireGuard tunnel) instead of stalling every
      # substitution on a connect timeout.
      connect-timeout = lib.mkDefault 5;
    };
  };
}
