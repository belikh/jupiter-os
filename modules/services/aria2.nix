{
  config,
  lib,
  pkgs,
  ...
}:

# aria2 download manager + AriaNg web UI.
#
# aria2 runs as a systemd service with JSON-RPC on :6800 bound to LOOPBACK
# ONLY (W1-T1: it previously listened on all interfaces with the port
# opened in the firewall and a public Cloudflare-tunnel route at
# rpc.jupiter.au — secret-only auth on a public ingress, plus the secret
# visible in /proc/<pid>/cmdline). Consumers:
#   - the arcade webapp (same host) talks to 127.0.0.1:6800 directly;
#   - AriaNg is served by nginx on :<port>, and its browser reaches the
#     daemon through the same-origin /jsonrpc reverse proxy below — the
#     daemon itself never leaves loopback and the RPC port is never opened
#     in the firewall.
# Remote (off-LAN) RPC access is a ledgered follow-up: re-add a tunnel
# route only behind a Cloudflare Access policy on the hostname
# (docs/plans/arcade-remediation-ledger.tsv W1-D1).
# The RPC secret is provided via sops (jupiter_aria2_rpc_secret), handed
# to the service through systemd LoadCredential, and passed to aria2 in a
# runtime conf file — it never appears in any process's argv.

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
        Host under which AriaNg (the web UI) reaches the JSON-RPC daemon.
        The daemon binds loopback only; AriaNg's browser hits the
        <literal>/jsonrpc</literal> reverse proxy on this module's nginx
        vhost, so this is the address BROWSERS on the LAN use to reach
        <option>port</option> — usually this host's routable LAN address
        (e.g. the NAS' <literal>10.1.1.2</literal>). Combine with
        <option>rpcProtocol</option> and <option>rpcWebPort</option> to
        build the exact URL AriaNg defaults to.
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
        Protocol AriaNg uses to reach the JSON-RPC daemon through the
        same-origin <literal>/jsonrpc</literal> proxy. Default
        <literal>http</literal> for the plain LAN path; set
        <literal>wss</literal>/<literal>https</literal> only when the
        AriaNg vhost itself is fronted by TLS termination.
      '';
    };

    rpcWebPort = lib.mkOption {
      type = lib.types.port;
      default = cfg.port;
      description = ''
        Port AriaNg uses to reach the JSON-RPC daemon. Defaults to the
        AriaNg vhost's own <option>port</option>: the
        <literal>/jsonrpc</literal> location on that vhost proxies to the
        loopback-bound daemon, so the RPC URL is same-origin with the UI.
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
        downloads land under the arcade-webapp's incoming root (submitted via the
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
      description = ''
        Open the AriaNg web UI and BitTorrent ports in the firewall for LAN
        access. The JSON-RPC port is deliberately NEVER opened: the daemon
        binds loopback only (W1-T1) and AriaNg reaches it through the
        same-origin nginx <literal>/jsonrpc</literal> proxy.
      '';
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

    # aria2 daemon. The RPC secret reaches the service via systemd
    # LoadCredential (from the sops file), and the wrapper writes it into a
    # runtime conf file (mode 0600, tmpfs) which aria2 reads via
    # --conf-path — aria2 has no --rpc-secret-file, and passing
    # --rpc-secret on the command line exposes it in /proc/<pid>/cmdline to
    # every local user (the W1-T1 exposure class).
    # WARNING: no shell comments (`#`) inside the ExecStart script below. The
    # script is built from this Nix string, and a `#` mid-command swallows the
    # backslash-continuation AND, because the script is `exec`, everything
    # after the comment block silently never runs (observed live: aria2 lost
    # --save-session/--max-concurrent-downloads/--enable-dht6 after the save-
    # session comments were added, until this was fixed).
    systemd.services.aria2 = {
      description = "aria2 download manager (JSON-RPC, loopback only)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "exec";
        User = "io";
        Group = "users";
        RuntimeDirectory = "aria2";
        LoadCredential = "aria2-rpc-secret:${config.sops.secrets.jupiter_aria2_rpc_secret.path}";
        ExecStart = pkgs.writeShellScript "aria2-exec" ''
          set -eu
          umask 077
          [ -s "$CREDENTIALS_DIRECTORY/aria2-rpc-secret" ] || exit 1
          CONF="$RUNTIME_DIRECTORY/aria2.conf"
          printf 'rpc-secret=%s\n' "$(cat "$CREDENTIALS_DIRECTORY/aria2-rpc-secret")" > "$CONF"
          exec ${pkgs.aria2}/bin/aria2c \
            --enable-rpc \
            --rpc-listen-all=false \
            --rpc-listen-port=${toString cfg.rpcPort} \
            --conf-path="$CONF" \
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
            --bt-max-peers=500 \
            --bt-request-peer-speed-limit=50K \
            --bt-max-open-files=20 \
            --check-integrity=false \
            --bt-seed-unverified=true \
            --bt-external-ip=157.85.248.45 \
            --seed-ratio=1.0 \
            --seed-time=60 \
            --dht-listen-port=${toString cfg.btListenPort} \
            --listen-port=${toString cfg.btListenPort} \
            --dht-file-path=${cfg.downloadDir}/aria2-dht.dat \
            --dht-file-path6=${cfg.downloadDir}/aria2-dht6.dat \
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
        # Same-origin reverse proxy to the loopback-bound JSON-RPC daemon
        # (W1-T1). The daemon never leaves 127.0.0.1; AriaNg's browser
        # posts to <vhost>/jsonrpc and nginx forwards. Auth is still the
        # RPC secret (entered once per browser, never embedded in the
        # served page). WebSocket upgrades are carried for ws:// configs.
        locations."/jsonrpc" = {
          proxyPass = "http://127.0.0.1:${toString cfg.rpcPort}";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_read_timeout 300s;
          '';
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
    # (DHT/tracker). cfg.rpcPort is deliberately absent: the daemon binds
    # loopback only and LAN clients go through the AriaNg vhost's /jsonrpc
    # proxy (W1-T1 — the RPC port was previously open to the LAN).
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [
      cfg.port
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
