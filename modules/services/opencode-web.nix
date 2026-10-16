{
  config,
  lib,
  pkgs,
  ...
}:

# opencode web UI — the vendor's own browser client, served headless and
# exposed through callisto's existing cloudflare tunnel. ONE instance running
# as a configurable account (default: io's rig; callisto points it at the
# "matt" second environment): the UI opens sessions in ANY subdirectory of
# the account's projects dir on the fly, so there is no static per-project
# port bookkeeping — "I have an idea" is just opening that folder in the UI.
# Multi-project/multi-thread = multiple in-UI sessions.
#
# Auth has three parts since opencode 2 (2026-10-15):
#   * Cloudflare Access on the public hostname — the real gate, and the only
#     user-facing one. Configured dashboard-side.
#   * opencode's HTTP basic auth (OPENCODE_SERVER_PASSWORD / serverPasswordFile)
#     on the origin itself, which v2 now requires unconditionally. v1 served
#     unsecured, so this layer did not exist before.
#   * the Caddy hop in front (authProxy below), whose only job is to make v2's
#     layer invisible to the browser. A browser will not authenticate itself:
#     the UI document GET / is served 200, then every /api/* fetch comes back
#     401, and browsers never raise a basic-auth dialog for fetch/XHR — so the
#     page loads and then silently does nothing. Caddy injects the credential
#     for tunnel traffic and nothing else changes. cloudflared still cannot
#     inject a header itself (no such option in its ingress rules), which is
#     why the hop exists rather than being configured in the tunnel.
# The client side (TUI, `opencode api`) is unaffected: those attach to the
# server directly and send the password from OPENCODE_PASSWORD.
let
  cfg = config.jupiter.services.opencodeWeb;
  home = "/home/${cfg.user}";
  # The launcher is the account's sops-keyed wrapper on the system PATH
  # (io: `opencode`; matt: `opencode-matt`). It exports the provider keys from
  # that account's readable secrets and execs the account's own
  # ~/.opencode/bin/opencode — so the serve process inherits the right keys
  # without this module hard-coding whose secrets to read.
  launcher = "/run/current-system/sw/bin/${cfg.launcher}";
  # OPENCODE_SERVER_PASSWORD turns on HTTP basic auth (user: opencode). The
  # optional envFile sources additional KEY=value lines; io's default points
  # at the fleet dsh_env secret (io-readable), while an account that cannot
  # read it (matt) sets it to null and relies on its launcher instead.
  envPreamble =
    (lib.optionalString (
      cfg.serverPasswordFile != null
    ) "export OPENCODE_SERVER_PASSWORD=\"$(cat ${cfg.serverPasswordFile})\"; ")
    + lib.optionalString (
      cfg.envFile != null
    ) "set -a; [ -f ${cfg.envFile} ] && . ${cfg.envFile}; set +a; ";
  # Caddy hop in front of the server for tunnel traffic: loopback-only, and
  # the only thing it does is inject the basic-auth credential that opencode 2
  # now always requires. `@@CREDENTIAL@@` is substituted at service start from
  # the sops secret, so nothing secret is baked into the store and a rotated
  # password is picked up on the next restart without a rebuild. flush_interval
  # -1 keeps the UI's /event stream unbuffered; the long timeouts keep
  # long-lived streaming sessions from being cut.
  #
  # Reuses the shape already proven on this host for design.jupiter.au
  # (open-design-web: Caddy in front of the daemon behind the tunnel).
  authProxyCaddyfile = pkgs.writeText "opencode-web-auth-proxy.Caddyfile" ''
    {
      auto_https off
      admin off
      persist_config off
    }

    http://127.0.0.1:${toString cfg.authProxy.port} {
      reverse_proxy 127.0.0.1:${toString cfg.port} {
        header_up Authorization "Basic @@CREDENTIAL@@"
        flush_interval -1
        transport http {
          read_timeout 86400s
          write_timeout 86400s
        }
      }
    }
  '';
in
{
  options.jupiter.services.opencodeWeb = {
    enable = lib.mkEnableOption "opencode web UI served via the cloudflare tunnel";

    user = lib.mkOption {
      type = lib.types.str;
      default = "io";
      description = "Account the web UI runs as (owns the projects dir and reads that account's secrets).";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "users";
      description = "Group the web UI runs as (use the account's own primary group when it is not the shared users group).";
    };

    launcher = lib.mkOption {
      type = lib.types.str;
      default = "opencode";
      description = "Name of the sops-keyed launcher wrapper on the system PATH (e.g. opencode, opencode-matt).";
    };

    envFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = config.sops.secrets.dsh_env.path;
      description = ''
        Optional env file sourced into the serve process (KEY=value lines).
        Defaults to the fleet dsh_env secret (io-readable). Set to null when
        the account cannot read it and its launcher already exports the keys
        (e.g. matt).
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 4096;
      description = "Local loopback port the opencode serve listens on (tunnel proxies to it).";
    };

    rootDir = lib.mkOption {
      type = lib.types.path;
      default = "/home/${cfg.user}/projects";
      description = "Directory the web UI opens projects from; any subdir is one click away.";
    };

    # Path to a file containing the opencode HTTP basic-auth password
    # (user: opencode). If null, the serve runs WITHOUT basic auth and MUST be
    # gated by Cloudflare Access (or another edge auth) on the public hostname
    # — do not expose it to the internet without one of the two. Wire a sops
    # secret here later, e.g. serverPasswordFile = config.sops.secrets.X.path.
    serverPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "File with OPENCODE_SERVER_PASSWORD; null = rely on Cloudflare Access.";
    };

    # The loopback Caddy hop that makes opencode 2's mandatory basic auth
    # invisible to browsers. Point the tunnel ingress at `authProxy.port`
    # instead of `port`; the server keeps its own auth for direct loopback
    # use. Defaults on whenever a server password is configured, because that
    # is exactly the case a browser cannot satisfy on its own.
    authProxy = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = cfg.serverPasswordFile != null;
        description = ''
          Run the Caddy hop in front of the server that injects the basic-auth
          credential. Required for any browser access on opencode 2, which
          always protects its server; the tunnel ingress must target this
          proxy's port rather than the server's.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 4097;
        description = "Loopback port the proxy listens on (the tunnel's upstream).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.opencode-web = {
      description = "opencode web UI (serve)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      # opencode spawns arbitrary user tools (git, bash, nix, ...) for its
      # bash tool. Without this the unit inherits systemd's minimal default
      # PATH (coreutils/grep/sed store paths only) and even `git` is
      # unrunnable (observed live 2026-08-28 on the serve process). Mirror the
      # target account's interactive login PATH — the NixOS symlink farms are
      # stable across switches, so anything in systemPackages / per-user
      # packages stays visible without touching this module.
      environment.PATH = lib.mkForce (
        lib.concatStringsSep ":" [
          "/run/wrappers/bin"
          "${home}/.nix-profile/bin"
          "/nix/profile/bin"
          "${home}/.local/state/nix/profile/bin"
          "/etc/profiles/per-user/${cfg.user}/bin"
          "/nix/var/nix/profiles/default/bin"
          "/run/current-system/sw/bin"
        ]
      );
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.rootDir;
        ExecStart = "${pkgs.bash}/bin/bash -c '${envPreamble}exec ${launcher} serve --port ${toString cfg.port} --hostname 127.0.0.1'";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    # Caddy hop in front of the server for tunnel traffic. The rendered
    # Caddyfile carries the credential and lives in the unit's own
    # RuntimeDirectory (0700).
    systemd.services.opencode-web-auth-proxy = lib.mkIf cfg.authProxy.enable {
      description = "Caddy hop in front of the opencode web UI (injects the server credential)";
      after = [
        "network-online.target"
        "opencode-web.service"
      ];
      wants = [
        "network.target"
        "network-online.target"
        "opencode-web.service"
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        RuntimeDirectory = "opencode-web-auth-proxy";
        RuntimeDirectoryMode = "0700";
        # Keep caddy out of the account's home: it only needs the config it is
        # handed plus a scratch dir for autosave (disabled in the Caddyfile).
        environment = [
          "XDG_DATA_HOME=/run/opencode-web-auth-proxy"
          "XDG_CONFIG_HOME=/run/opencode-web-auth-proxy"
        ];
        # The credential is rendered into the RuntimeDirectory rather than
        # passed as an argument, so it never appears in `ps` output or in the
        # unit's environment.
        ExecStart = ''
          set -euo pipefail
          dir=/run/opencode-web-auth-proxy
          umask 077
          cred=$(printf 'opencode:%s' "$(cat ${cfg.serverPasswordFile})" | ${pkgs.coreutils}/bin/base64 -w0)
          ${pkgs.gnused}/bin/sed "s|@@CREDENTIAL@@|$cred|" ${authProxyCaddyfile} > "$dir/Caddyfile"
          # Canonicalise the formatting in place so caddy doesn't warn about an
          # unformatted Caddyfile on every start (the store copy is indented
          # to suit the Nix source, not caddy's tab style).
          ${lib.getExe pkgs.caddy} fmt --overwrite "$dir/Caddyfile"
          exec ${lib.getExe pkgs.caddy} run --config "$dir/Caddyfile" --adapter caddyfile
        '';
        Restart = "on-failure";
        RestartSec = 5;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
      };
    };
  };
}
