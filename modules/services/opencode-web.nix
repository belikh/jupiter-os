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
  };

  config = lib.mkIf cfg.enable {
    # HTTP basic-auth password for the opencode server (user: opencode).
    sops.secrets.opencode_server_password = {
      owner = "io";
      mode = "0400";
    };

    systemd.services.opencode-web = {
      description = "opencode web UI (serve)";
      after = [ "network-online.target" "sops-nix.service" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        User = "io";
        Group = "users";
        WorkingDirectory = cfg.rootDir;
        # Keys come from the pinned wrapper at /run/current-system/sw/bin/opencode
        # (which execs the chmod-0555 1.18.22 binary). OPENCODE_SERVER_PASSWORD
        # turns on HTTP basic auth so the tunnel-facing UI isn't open.
        ExecStart = "${pkgs.bash}/bin/bash -c 'export OPENCODE_SERVER_PASSWORD=\"$(cat ${config.sops.secrets.opencode_server_password.path})\"; exec /run/current-system/sw/bin/opencode serve --port ${toString cfg.port} --hostname 127.0.0.1'";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
