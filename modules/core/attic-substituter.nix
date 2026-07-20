{
  config,
  lib,
  ...
}:

# Subscribe every host in the fleet to the attic binary cache hosted on
# europa (see modules/services/attic-server.nix). Without this, only europa
# itself consumes from the attic — every other host falls through to
# cache.nixos.org, which does not carry gccarch-tagged paths. That matters
# acutely for callisto (the fleet builder): without attic access it cannot
# substitute europa's btver2-tuned derivations when other hosts delegate
# them, so it rebuilds the entire stage0 toolchain from scratch — the
# 6-hour LLVM build we hit during callisto's first bring-up.
#
# europa is both server and consumer — for it, the loopback URL avoids a
# network roundtrip. Every other host reaches the same atticd over the LAN
# at europa's reserved IP (10.1.1.2 — UniFi DHCP reservation, see
# modules/core/build-machines.nix's note).

let
  cfg = config.jupiter.core.atticSubstituter;
  isAtticServer = config.jupiter.services.attic.enable or false;
  host = if isAtticServer then "localhost" else cfg.serverIp;
  url = "http://${host}:${toString cfg.port}/${cfg.cacheName}";
in
{
  options.jupiter.core.atticSubstituter = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Subscribe this host to europa's attic binary cache ahead of
        cache.nixos.org. Default-on for every fleet host: the attic is the
        only source for gccarch-tagged paths.
      '';
    };

    serverIp = lib.mkOption {
      type = lib.types.str;
      default = "10.1.1.2";
      description = ''
        europa's LAN IP — every host but europa itself reaches atticd here.
        Ignored on hosts where jupiter.services.attic.enable is true (they
        use localhost instead).
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port atticd listens on (matches modules/services/attic-server.nix).";
    };

    cacheName = lib.mkOption {
      type = lib.types.str;
      default = "jupiter-os";
      description = "Attic cache name (matches modules/services/attic-server.nix).";
    };

    publicKey = lib.mkOption {
      type = lib.types.str;
      default = "jupiter-os:jd6naJxSxt9xPtYTaOSQDOoeoHil5OsVy8ltpIBs9dQ=";
      description = ''
        Attic cache public key (matches modules/services/attic-server.nix).
        Minted once via `attic cache create <cacheName>` — see
        docs/europa-bringup-stages.md.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    nix.settings = {
      substituters = [ url ];
      trusted-public-keys = [ cfg.publicKey ];
    };
  };
}
