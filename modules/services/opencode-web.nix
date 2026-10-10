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
# Multi-project/multi-thread = multiple in-UI sessions. Auth is two layers:
# opencode's HTTP basic auth (OPENCODE_SERVER_PASSWORD) PLUS Cloudflare Access
# on the public hostname (configured dashboard-side). The cloudflare ingress
# rule itself is added in the host config (callisto) alongside the other
# tunnel ingress rules.
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
  };
}
