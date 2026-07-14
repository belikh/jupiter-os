{ config, lib, ... }:

# Runs atticd, the binary cache the ephemeral BinaryLane "rebuild the world"
# build server pushes CPU-tuned closures into, and the rest of the fleet
# pulls from ahead of cache.nixos.org.
#
# Phase 1 (bootstrap): atticd runs and accepts pushes, but no hosts are
# configured to substitute from it yet — that comes in Phase 2 when the
# first tuned closure is pushed.
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

    # Allow direct access on the LAN (Cloudflare Tunnel will also reach in
    # without an open port, once configured).
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
