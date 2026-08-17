{
  config,
  lib,
  pkgs,
  ...
}:

# suno-web — a browser UI for the Suno archive that
# modules/services/suno-backup.nix mirrors into `tank/archive/suno`.
#
# The backup daemon writes tracks/<YYYY>/<MM>/<id>/{<id>.wav, cover.jpg,
# meta.json}; this service indexes those meta.json files in memory and serves
# search, metadata filtering, the clip derivation graph (covers/extends/stems/
# mashups/personas), playlists, and Range-seekable playback of the WAV masters.
#
# Read-only against the archive: `dataDir` is mounted ReadOnlyPaths, and the
# one thing this service owns — user-made playlists — lives in its
# StateDirectory instead. That separation is deliberate: playlists are the only
# data here that cannot be re-derived from Suno, and writing them into
# tank/archive/suno would break that dataset's role as a faithful mirror (it is
# snapshotted as one by modules/storage/sanoid.nix).
let
  cfg = config.jupiter.services.sunoWeb;

  inherit (import ../lib.nix { inherit config lib pkgs; }) commonServiceHardening;
in
{
  options.jupiter.services.sunoWeb = {
    enable = lib.mkEnableOption ''
      suno-web: a browser UI over the archived Suno library — full-text and
      metadata search, persona/voice browsing, the clip derivation graph,
      playlists, and WAV playback
    '';

    package = lib.mkOption {
      type = lib.types.package;
      description = ''
        The suno-web package to run. Supplied by flake.nix's `sunoWebModule`
        lexical closure from the `suno-web` flake input
        (github:belikh/suno-web), following the same pattern as europa's
        `pxeModule` — the source lives in its own repository rather than
        in-tree, so this module has nothing to `callPackage`.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8093;
      description = "TCP port the service listens on (nom-web holds 8092).";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      # Literal, NOT config.jupiter.services.sunoBackup.dataDir: a
      # cross-module default would throw "option does not exist" on any host
      # that imports this module without suno-backup.nix. The literal matches
      # sunoBackup.dataDir's own default — keep the two in sync, or set this
      # explicitly when they differ.
      default = "/tank/archive/suno";
      description = ''
        Root of the Suno archive — the same path the backup daemon
        (modules/services/suno-backup.nix) writes. Mounted read-only; the
        service never writes here.
      '';
    };

    refreshInterval = lib.mkOption {
      type = lib.types.str;
      default = "5m";
      description = ''
        How often the index re-walks the archive for newly backed-up clips
        (Go duration string). A pass only stats directories and parses clips it
        has not seen, so this stays cheap while the daemon is still
        backfilling history.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open `port` in the firewall for the trusted LAN. Left off by default:
        the WAV masters are 35-45MB each, so this is a LAN-first service —
        exposing it through the Cloudflare Tunnel would want on-the-fly
        transcoding first.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.jupiter-suno-web = {
      description = "suno-web (browser UI for the archived Suno library)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      # Don't start until the archive dataset is mounted (mirrors
      # suno-backup.nix / rom-acquire.nix).
      unitConfig.RequiresMountsFor = [ cfg.dataDir ];

      environment = {
        SUNOWEB_DATA_DIR = cfg.dataDir;
        SUNOWEB_STATE_DIR = "/var/lib/jupiter-suno-web";
        SUNOWEB_PORT = toString cfg.port;
        SUNOWEB_REFRESH = cfg.refreshInterval;
      };

      serviceConfig = {
        Type = "exec";
        ExecStart = "${lib.getExe cfg.package}";
        Restart = "on-failure";
        RestartSec = "10s";
        DynamicUser = true;

        # Playlists + the derived index cache. StateDirectory gives us
        # /var/lib/jupiter-suno-web created with the right ownership under
        # DynamicUser, which a hand-rolled tmpfiles rule would have to
        # reproduce.
        StateDirectory = "jupiter-suno-web";
        StateDirectoryMode = "0750";

        # Hardening: read-only access to the archive, a listening socket, and
        # its own state directory. Nothing else. Common stanza shared with
        # nom-web/suno-backup (modules/lib.nix: commonServiceHardening).
        ReadOnlyPaths = [ cfg.dataDir ];
      }
      // commonServiceHardening;
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
