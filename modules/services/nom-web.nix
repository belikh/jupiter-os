{
  config,
  lib,
  pkgs,
  ...
}:

# nom-web — a web UI for nix's internal-json build logs (a browser port of
# nix-output-monitor). Reads *.jsonl files out of `logDir` (intended to be
# an NFS mount of europa's /var/log/jupiter-ci, where ci-distributed.yml
# already writes every fleet build's raw --log-format internal-json stream —
# see modules/storage/nas-nfs.nix for the export side) and serves both a
# listing of finished runs and a live view of whichever one current.jsonl
# points at.
#
# Reached publicly at nom.jupiter.au via europa's Cloudflare Tunnel, whose
# extraIngress now supports proxying to a non-localhost host (see
# modules/services/cloudflare-tunnel.nix) — the tunnel forwards to this
# service's LAN address.
let
  cfg = config.jupiter.services.nomWeb;

  pkg = pkgs.callPackage ../../pkgs/nom-web { };
in
{
  options.jupiter.services.nomWeb = {
    enable = lib.mkEnableOption ''
      nom-web: a browser UI for nix's internal-json build logs, reading
      *.jsonl files out of logDir
    '';

    port = lib.mkOption {
      type = lib.types.port;
      default = 8092;
      description = "TCP port the service listens on.";
    };

    logDir = lib.mkOption {
      type = lib.types.path;
      default = "/mnt/jupiter-ci-logs";
      description = ''
        Directory containing `nom-<run>.jsonl` files and a `current.jsonl`
        symlink to whichever one is live. Read-only — the service never
        writes here. On callisto this is the NFS mount of europa's
        /var/log/jupiter-ci.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open `port` in the firewall (intended for the trusted LAN, so the tunnel host can reach it).";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.jupiter-nom-web = {
      description = "nom-web (browser UI for nix internal-json build logs)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      unitConfig.RequiresMountsFor = [ cfg.logDir ];

      environment = {
        NOMWEB_LOG_DIR = cfg.logDir;
        NOMWEB_PORT = toString cfg.port;
      };

      serviceConfig = {
        Type = "exec";
        ExecStart = "${lib.getExe pkg}";
        Restart = "on-failure";
        RestartSec = "10s";
        DynamicUser = true;

        # Hardening: read-only access to the log mount, a listening socket,
        # nothing else.
        ReadOnlyPaths = [ cfg.logDir ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = false; # Go runtime needs writable+executable memory
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
