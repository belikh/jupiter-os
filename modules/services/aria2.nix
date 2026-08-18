{
  config,
  lib,
  pkgs,
  ...
}:

# aria2 download manager + AriaNg web UI.
#
# aria2 runs as a systemd service with JSON-RPC on localhost:6800.
# AriaNg (pure HTML/JS) is served via nginx on a separate port.
# RPC secret is provided via sops (jupiter_aria2_rpc_secret).

let
  cfg = config.jupiter.services.aria2;

  # Fetch AriaNg release from GitHub. The AllInOne zip is a flat archive
  # (index.html + assets at the zip root), so fetchzip needs stripRoot=false.
  ariaNg = pkgs.fetchzip {
    url = "https://github.com/mayswind/AriaNg/releases/download/1.3.12/AriaNg-1.3.12-AllInOne.zip";
    sha256 = "1l2is4yr0jap9lxawwpj45ga9im2px35qghkanj7hgxvlzwkhmgy";
    stripRoot = false;
  };
in
{
  options.jupiter.services.aria2 = {
    enable = lib.mkEnableOption "aria2 download manager with AriaNg web UI";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8083;
      description = "TCP port for AriaNg web UI (nginx)";
    };

    rpcPort = lib.mkOption {
      type = lib.types.port;
      default = 6800;
      description = "TCP port for aria2 JSON-RPC";
    };

    downloadDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/downloads";
      description = "Directory where aria2 stores completed downloads";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open RPC and web UI ports in firewall for LAN access";
    };
  };

  config = lib.mkIf cfg.enable {
    # Ensure download directory exists
    systemd.tmpfiles.rules = [
      "d ${cfg.downloadDir} 0755 io users -"
    ];

    # aria2 daemon. The RPC secret is read from the sops file at runtime:
    # sops secrets are only decryptable at activation, so the ExecStart
    # caches the value via `$(cat ...)` (aria2 has no --rpc-secret-file).
    systemd.services.aria2 = {
      description = "aria2 download manager (JSON-RPC)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "exec";
        User = "io";
        Group = "users";
        ExecStart = pkgs.writeShellScript "aria2-exec" ''
          set -eu
          exec ${pkgs.aria2}/bin/aria2c \
            --enable-rpc \
            --rpc-listen-all=false \
            --rpc-listen-port=${toString cfg.rpcPort} \
            --rpc-secret="$(cat ${config.sops.secrets.jupiter_aria2_rpc_secret.path})" \
            --dir=${cfg.downloadDir} \
            --file-allocation=falloc \
            --continue=true \
            --max-concurrent-downloads=5 \
            --max-connection-per-server=16 \
            --min-split-size=1M \
            --split=16 \
            --bt-max-peers=55 \
            --bt-request-peer-speed-limit=50K \
            --seed-ratio=1.0 \
            --seed-time=60 \
            --dht-listen-port=6881 \
            --listen-port=6881
        '';
        Restart = "on-failure";
        RestartSec = "10s";
        # Hardening
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        ReadWritePaths = [ cfg.downloadDir ];
      };
    };

    # AriaNg static files via nginx
    services.nginx = {
      enable = true;
      virtualHosts."ariang" = {
        listen = [
          {
            addr = "0.0.0.0";
            port = cfg.port;
          }
        ];
        root = ariaNg;
        # AriaNg is a SPA - serve index.html for all routes
        locations."/" = {
          tryFiles = "$uri $uri/ /index.html";
        };
        # CORS headers for aria2 RPC (if accessed directly)
        extraConfig = ''
          add_header Access-Control-Allow-Origin "*";
          add_header Access-Control-Allow-Methods "GET, POST, OPTIONS";
          add_header Access-Control-Allow-Headers "Content-Type";
        '';
      };
    };

    # Firewall
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [
      cfg.port
      cfg.rpcPort
    ];

    # Ensure RPC secret is available (declared unconditionally - the RPC
    # secret is required for the JSON-RPC endpoint to authenticate).
    sops.secrets.jupiter_aria2_rpc_secret = { };
  };
}
