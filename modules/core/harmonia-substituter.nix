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
# The harmonia server (europa) deliberately does NOT subscribe to itself. The
# cache it serves IS its own /nix/store, so a path harmonia can offer is one the
# host already has — isValidPath() short-circuits before substitution and the
# substituter is never consulted. It can therefore only ever be reached for paths
# europa does NOT have, which harmonia also 404s. Net gain: zero.
#
# The one case where it does answer is the pathological one (issue #67): a path
# registered valid in the DB but missing from disk. Harmonia builds narinfos from
# that same DB, so it advertises the phantom with a 200 and then cannot produce a
# NAR, turning every substitution into a five-deep retry storm of
#   "HTTP error 200 (curl error: Transferred a partial file)".
# Subscribing the server to itself buys nothing and hides real corruption behind
# noise, so it is skipped.
#
# Every other host reaches harmonia over the LAN at europa's reserved IP
# (10.1.1.2 — UniFi DHCP reservation). CI runners (GitHub Actions) reach it over
# the UDM WireGuard road-warrior, also at 10.1.1.2:5000.
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
  imports = [ ../network/fleet.nix ];

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
      default = config.jupiter.fleet.addresses.europa;
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
      default = "jupiter-cache-1:5tPIwQSj5/mk53jBHqqsAk9IpcuTGz/2UQOdHvjTId0=";
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
      # Skipped on the harmonia server itself — see the header comment: it would
      # be subscribing to its own /nix/store, which can only ever answer for
      # paths it already has (never consulted) or paths it has lost (#67 retry
      # storm). The public key is still trusted here, because europa verifies
      # signatures on the closures CI pushes in over SSH.
      substituters = lib.optionals (!isHarmoniaServer) [ url ];
      trusted-public-keys = [ cfg.publicKey ];
      # Fail fast if Harmonia is unreachable (e.g. a PR-side CI run that
      # hasn't brought up the WireGuard tunnel) instead of stalling every
      # substitution on a connect timeout.
      connect-timeout = lib.mkDefault 60;
      # Never-disable posture: nix disables a substituter for 60s per failed
      # download (window hardcoded upstream), so keep failures rare instead —
      # ride out zero-data stalls (Tailscale DERP relays trickle) rather than
      # erroring into a disable.
      stalled-download-timeout = lib.mkDefault 900;
    };
  };
}
