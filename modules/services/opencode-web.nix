{
  config,
  lib,
  pkgs,
  ...
}:

# opencode web UI — the vendor's own browser client, served headless and
# exposed through callisto's existing cloudflare tunnel. ONE instance, cwd at
# /home/io/projects: the UI opens sessions in ANY subdirectory on the fly, so
# there is no static per-project port bookkeeping — "I have an idea" is just
# opening that folder in the UI. Multi-project/multi-thread = multiple in-UI
# sessions. Auth is two layers: opencode's HTTP basic auth (OPENCODE_SERVER_
# PASSWORD) PLUS Cloudflare Access on the public hostname (configured
# dashboard-side). The cloudflare ingress rule itself is added in the host
# config (callisto) next to the existing dsh.jupiter.au rule.
let
  cfg = config.jupiter.services.opencodeWeb;
in
{
  options.jupiter.services.opencodeWeb = {
    enable = lib.mkEnableOption "opencode web UI served via the cloudflare tunnel";

    port = lib.mkOption {
      type = lib.types.port;
      default = 4096;
      description = "Local loopback port the opencode serve listens on (tunnel proxies to it).";
    };

    rootDir = lib.mkOption {
      type = lib.types.path;
      default = /home/io/projects;
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
  };

  config = lib.mkIf cfg.enable {
    systemd.services.opencode-web = {
      description = "opencode web UI (serve)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        User = "io";
        Group = "users";
        WorkingDirectory = cfg.rootDir;
        # Keys come from the pinned wrapper at /run/current-system/sw/bin/opencode
        # (which execs the chmod-0555 1.18.22 binary). With serverPasswordFile
        # set, OPENCODE_SERVER_PASSWORD turns on HTTP basic auth.
        ExecStart =
          if cfg.serverPasswordFile != null
          then "${pkgs.bash}/bin/bash -c 'export OPENCODE_SERVER_PASSWORD=\"$(cat ${cfg.serverPasswordFile})\"; exec /run/current-system/sw/bin/opencode serve --port ${toString cfg.port} --hostname 127.0.0.1'"
          else "/run/current-system/sw/bin/opencode serve --port ${toString cfg.port} --hostname 127.0.0.1";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
