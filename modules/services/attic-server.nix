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

    # Allow direct access on the LAN (Cloudflare Tunnel will also reach in
    # without an open port, once configured).
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
