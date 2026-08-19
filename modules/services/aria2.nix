{
  config,
  lib,
  pkgs,
  ...
}:

# aria2 download manager + AriaNg web UI.
#
# aria2 runs as a systemd service with JSON-RPC on :6800, bound to all
# interfaces so AriaNg and other LAN clients can reach it (auth is via the
# RPC secret, never via network isolation). AriaNg (pure HTML/JS) is served
# via nginx on a separate port. RPC secret is provided via sops
# (jupiter_aria2_rpc_secret).

let
  cfg = config.jupiter.services.aria2;

  # AriaNg built from source (see pkgs/ariang): upstream master d6a7653 +
  # the in-tree task-name-from-dir patch, with the dist/ output served
  # directly. Building from source lets the patch apply cleanly where the
  # old prebuilt AllInOne zip (1.3.12) had no source-level patch site.
  ariaNg = pkgs.callPackage ../../pkgs/ariang { };
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

    rpcHost = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Host under which AriaNg (the web UI) reaches the JSON-RPC daemon. The
        daemon binds all interfaces (<literal>--rpc-listen-all</literal>); over
        the LAN it is usually the routable host (e.g. the NAS'
        <literal>10.1.1.2</literal>), or a public/TLS reverse-proxy hostname
        when the endpoint is fronted by a tunnel (see europa's
        <literal>rpc.jupiter.au</literal>). Combine with
        <option>rpcProtocol</option> and <option>rpcWebPort</option> to build
        the exact URL AriaNg defaults to.
      '';
    };

    rpcProtocol = lib.mkOption {
      type = lib.types.enum [
        "http"
        "https"
        "ws"
        "wss"
      ];
      default = "http";
      description = ''
        Protocol AriaNg uses to reach the JSON-RPC daemon. Default
        <literal>http</literal> for a plain LAN endpoint; set
        <literal>wss</literal> when the endpoint is fronted by TLS/WebSocket
        termination (e.g. europa's <literal>rpc.jupiter.au</literal> via
        cloudflared), or <literal>https</literal>/<literal>ws</literal> as
        appropriate.
      '';
    };

    rpcWebPort = lib.mkOption {
      type = lib.types.port;
      default = 6800;
      description = ''
        Port AriaNg uses to reach the JSON-RPC daemon. Defaults to the daemon's
        local <option>rpcPort</option> (6800); set to 443 when the endpoint is
        fronted by a TLS-terminating reverse proxy / tunnel.
      '';
    };

    downloadDir = lib.mkOption {
      type = lib.types.str;
      default = "/tank/downloads";
      description = "Directory where aria2 stores completed downloads";
    };

    extraWritableDirs = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = ''
        Additional directories the daemon may write to besides
        <option>downloadDir</option>. The arcade's per-system torrent
        downloads land under the rom-acquire incoming root (submitted via the
        RPC <literal>dir=</literal> option), which is outside the default
        download dir — list that root here so <literal>ProtectSystem=strict</literal>
        doesn't block the daemon's writes. Each entry gets a tmpfiles rule
        (created as <literal>io:users</literal>) plus a
        <literal>ReadWritePaths</literal> entry.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open RPC and web UI ports in firewall for LAN access";
    };

    btListenPort = lib.mkOption {
      type = lib.types.port;
      default = 6881;
      description = "TCP/UDP port for incoming BitTorrent peer connections and DHT";
    };

    dhtListenAddr6 = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Global unicast IPv6 address the IPv6 DHT socket binds to
        (<literal>--dht-listen-addr6</literal>). Set to the host's stable
        global address to enable IPv6 DHT (<literal>--enable-dht6</literal>).
        Leave <literal>null</literal> to keep IPv6 DHT disabled.
      '';
    };

    maxConcurrentDownloads = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 2;
      description = ''
        Number of simultaneous downloads aria2 runs
        (<literal>--max-concurrent-downloads</literal>). aria2 holds each
        queued torrent's metainfo + file list + bitfield in memory regardless
        of concurrency, but each active download also adds its connection
        sockets and peer state. Kept low (2) on europa: the bulk No-Intro
        queue is large enough that a higher value pushes the daemon into the
        GBs and, on a 7.7GB ZFS host, into the OOM killer (see
        <option>memoryMax</option>).
      '';
    };

    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = "3G";
      description = ''
        Hard memory ceiling for the daemon (systemd <literal>MemoryMax</literal>).
        When exceeded the kernel OOM-kills aria2 inside its own cgroup rather
        than starving the whole host (ZFS ARC is separately capped). europa was
        OOM-killed at ~5.3GB anon-RSS on 7.7GB total; 3G keeps the daemon clear
        of that while leaving headroom for ARC + system services.
      '';
    };

    memoryHigh = lib.mkOption {
      type = lib.types.str;
      default = "2G";
      description = ''
        Soft memory ceiling (systemd <literal>MemoryHigh</literal>). Reclaim
        starts throttling the cgroup above this before the
        <option>memoryMax</option> hard kill triggers.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Ensure download directory exists
    systemd.tmpfiles.rules = [
      "d ${cfg.downloadDir} 0755 io users -"
      # aria2 hard-fails at startup if --input-file doesn't exist (exit 1,
      # "Failed to open the file .../aria2.session"), so pre-create it.
      "f ${cfg.downloadDir}/aria2.session 0644 io users -"
    ]
    ++ map (dir: "d ${dir} 0755 io users -") cfg.extraWritableDirs;

    # aria2 daemon. The RPC secret is read from the sops file at runtime:
    # sops secrets are only decryptable at activation, so the ExecStart
    # caches the value via `$(cat ...)` (aria2 has no --rpc-secret-file).
    # WARNING: no shell comments (`#`) inside the ExecStart script below. The
    # script is built from this Nix string, and a `#` mid-command swallows the
    # backslash-continuation AND, because the script is `exec`, everything
    # after the comment block silently never runs (observed live: aria2 lost
    # --save-session/--max-concurrent-downloads/--enable-dht6 after the save-
    # session comments were added, until this was fixed).
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
            --rpc-listen-all=true \
            --rpc-listen-port=${toString cfg.rpcPort} \
            --rpc-secret="$(cat ${config.sops.secrets.jupiter_aria2_rpc_secret.path})" \
            --rpc-max-request-size=64M \
            --dir=${cfg.downloadDir} \
            --file-allocation=falloc \
            --continue=true \
            --save-session=${cfg.downloadDir}/aria2.session \
            --save-session-interval=60 \
            --input-file=${cfg.downloadDir}/aria2.session \
            --max-concurrent-downloads=${toString cfg.maxConcurrentDownloads} \
            --max-connection-per-server=16 \
            --min-split-size=1M \
            --split=16 \
            --bt-max-peers=1000 \
            --bt-request-peer-speed-limit=50K \
            --seed-ratio=1.0 \
            --seed-time=60 \
            --dht-listen-port=${toString cfg.btListenPort} \
            --listen-port=${toString cfg.btListenPort} \
            ${lib.optionalString (
              cfg.dhtListenAddr6 != null
            ) "--enable-dht6=true --dht-listen-addr6=${cfg.dhtListenAddr6} "}
        '';
        Restart = "on-failure";
        RestartSec = "10s";
        # Memory ceiling: aria2's RSS grows with the queued-torrent count and is
        # only released on exit. Cap the cgroup so an OOM kills aria2 alone
        # instead of taking down the ZFS host (see options.memoryMax/memoryHigh).
        MemoryMax = cfg.memoryMax;
        MemoryHigh = cfg.memoryHigh;
        # Hardening
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        ReadWritePaths = [ cfg.downloadDir ] ++ cfg.extraWritableDirs;
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
        # Default AriaNg straight to the daemon's RPC settings so the "missing
        # RPC settings" don't have to be hand-entered on first visit. AriaNg
        # (no static config.js in this version) reads its RPC host/port/path
        # from the Command-API hash, so an exact-`/` redirect to that hash
        # pre-seeds them (the hash travels to the browser, never to nginx).
        # The RPC secret is intentionally left out — embedding it on the LAN
        # would defeat the daemon's auth. Each browser enters it once.
        # NOTE: the redirect target is `/index.html#!...`, NOT `/#!...`: a 302
        # to `/` would loop forever, because the browser strips the hash
        # fragment before requesting (it's client-side state), so every request
        # lands back on `= /` and redirects again (ERR_TOO_MANY_REDIRECTS on
        # the LAN path). `/index.html` is a real file (served 200) and the hash
        # still reaches AriaNg's JS — one redirect, no loop.
        locations."= /" = {
          return = "302 /index.html#!/settings/rpc/set/${cfg.rpcProtocol}/${cfg.rpcHost}/${toString cfg.rpcWebPort}/jsonrpc";
        };
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

    # Firewall. The BT listen port needs both TCP (peer connections) and UDP
    # (DHT/tracker).
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [
      cfg.port
      cfg.rpcPort
      cfg.btListenPort
    ];
    networking.firewall.allowedUDPPorts = lib.mkIf cfg.openFirewall [
      cfg.btListenPort
    ];

    # Ensure RPC secret is available (declared unconditionally - the RPC
    # secret is required for the JSON-RPC endpoint to authenticate). The
    # service runs as io:users, so the secret file must be readable by that
    # user (sops defaults to 0400 root:root).
    sops.secrets.jupiter_aria2_rpc_secret = {
      owner = "io";
      group = "users";
      mode = "0400";
    };
  };
}
