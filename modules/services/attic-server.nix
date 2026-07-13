{
  config,
  lib,
  ...
}:

# Runs atticd, the binary cache the ephemeral BinaryLane "rebuild the world"
# build server pushes CPU-tuned closures into, and configures THIS host to
# substitute from it ahead of cache.nixos.org.
#
# On europa the host IS the server, so its substituter points at localhost
# (no tunnel roundtrip). The build server and future roaming hosts reach the
# same atticd over the public tunnel at attic.jupiter.au.
#
# Storage lives on tank/services/attic (created by the zfs-nas module's
# dataset service), not backed up offsite (reproducible bulk state).

let
  cfg = config.jupiter.services.attic;
in
{
  options.jupiter.services.attic = {
    enable = lib.mkEnableOption "the atticd binary cache server";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port atticd listens on.";
    };

    storagePath = lib.mkOption {
      type = lib.types.path;
      default = "/tank/services/attic";
      description = ''
        Where atticd stores its cache objects and sqlite database. Lives on
        tank — bulk, reproducible state (every object here can just be
        rebuilt), so it's deliberately NOT part of the offsite restic set.
      '';
    };

    cacheName = lib.mkOption {
      type = lib.types.str;
      default = "jupiter-os";
      description = ''
        Name of the attic cache to substitute from. Must be created once
        atticd is live via `attic cache create <name>` — that command also
        mints the cache's public key, which must then be set in
        `publicKey` below.
      '';
    };

    publicKey = lib.mkOption {
      type = lib.types.str;
      default = "jupiter-os:TODO-replace-after-attic-cache-create";
      description = ''
        The attic cache's public key (a `name:base64...` string). Generated
        by `attic cache create <cacheName>` once atticd is running — copy the
        printed key here. Until it's set, the substituter entry is present
        but untrusted (nix will simply fall through to cache.nixos.org), so
        the host keeps building from the public cache. This is the bootstrap
        gap noted as Q4 in the Phase 2 plan.
      '';
    };

    substituterEnable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to configure this host to substitute from the local attic
        ahead of cache.nixos.org. Defaults to true: the NAS hosts its own
        cache and should prefer it. Set false on a host that runs atticd
        but should not consume from it (none today).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets.attic_server_token_secret = { };

    # atticd on NixOS defaults to DynamicUser + StateDirectory=/var/lib/atticd.
    # We keep its bulky state on tank/services/attic instead, which a
    # dynamically-allocated UID can't own (its UID changes each boot and
    # /tank/services/attic is root-owned). Pin a fixed system user that owns
    # the tank paths, and widen ReadWritePaths to the parent so the sqlite DB
    # (${storagePath}/server.db) is writable alongside the object storage.
    users.users.atticd = {
      isSystemUser = true;
      group = "atticd";
      home = cfg.storagePath;
    };
    users.groups.atticd = { };

    services.atticd = {
      enable = true;
      environmentFile = config.sops.secrets.attic_server_token_secret.path;
      settings = {
        listen = "[::]:${toString cfg.port}";
        database.url = "sqlite://${cfg.storagePath}/server.db?mode=rwc";
        storage = {
          type = "local";
          path = "${cfg.storagePath}/storage";
        };
      };
    };

    systemd.services.atticd.serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "atticd";
      Group = "atticd";
      ReadWritePaths = [ cfg.storagePath ];
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.storagePath} 0755 atticd atticd -"
      "d ${cfg.storagePath}/storage 0755 atticd atticd -"
    ];

    # Allow direct access on the LAN (the Cloudflare Tunnel also reaches in
    # without an open port, once configured).
    networking.firewall.allowedTCPPorts = [ cfg.port ];

    # ---- Substituter consumer ----------------------------------------------
    # This host pulls its own (tuned) closure from the local attic. europa IS
    # the server, so localhost avoids the tunnel roundtrip. The cache public
    # key gates whether nix actually trusts these paths — until
    # `attic cache create` mints the real key, nix falls through to
    # cache.nixos.org (harmless: the host just keeps building untuned).
    nix.settings = lib.mkIf cfg.substituterEnable {
      substituters = [
        "http://localhost:${toString cfg.port}/${cfg.cacheName}"
      ];
      trusted-public-keys = [ cfg.publicKey ];
    };
  };
}
