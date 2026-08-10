{
  config,
  lib,
  pkgs,
  ...
}:

# Aeon autonomous agent framework — dashboard service.
#
# Runs the aeon dashboard (Next.js dev server) on the host. The dashboard
# manages a fork of aeonfun/aeon (e.g. belikh/agent) via the `gh` CLI:
# all config (aeon.yml, STRATEGY.md, SOUL.md, skills, schedules, API keys,
# notifications) is done through the web UI — nothing aeon-specific lives
# in the Nix config beyond the gh token and repo URL.
#
# GitHub Actions runs the actual skills on cron in the fork's repo — this
# host only serves the dashboard UI + CLI. See pkgs/aeon/default.nix for
# the package build (deps installed offline via fetchNpmDeps; `next dev`
# runs at runtime because `next build` needs to fetch Google Fonts, which
# the Nix sandbox can't do).
let
  cfg = config.jupiter.services.aeon;

  # The aeon dashboard package from pkgs/aeon/default.nix — contains
  # node_modules + source for `next dev`.
  aeonPkg = pkgs.callPackage ../../pkgs/aeon/default.nix { };

  # Derive owner/repo from the repoUrl for gh repo set-default + clone
  # repoUrl format: "github:owner/repo"
  repoSlug = lib.removePrefix "github:" cfg.repoUrl;
in
{
  options.jupiter.services.aeon = {
    enable = lib.mkEnableOption "Aeon dashboard (autonomous agent framework web UI)";

    package = lib.mkPackageOption pkgs "aeon-dashboard" { } // {
      default = aeonPkg.dashboard;
    };

    repoUrl = lib.mkOption {
      type = lib.types.str;
      default = "github:belikh/agent";
      description = ''
        GitHub fork URL in `github:owner/repo` format. Cloned to the state
        directory on first start; the dashboard reads/writes it via `gh`.
      '';
    };

    ghTokenFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to a GitHub PAT (sops secret) with `repo` scope for the fork.
        Used by `gh auth login --with-token` in ExecStartPre.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5555;
      description = "Port the dashboard listens on.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Address the dashboard binds.";
    };

    exposeLan = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the dashboard port on the LAN firewall.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Dedicated user — the dashboard should not run as root.
    users.users.aeon = {
      isSystemUser = true;
      group = "aeon";
      home = "/var/lib/aeon";
      createHome = true;
    };
    users.groups.aeon = { };

    # State directory holds:
    #   - The fork clone (belikh/agent) — the repo the dashboard manages
    #   - gh auth config (~/.config/gh)
    systemd.tmpfiles.rules = [
      "d /var/lib/aeon 0755 aeon aeon - -"
    ];

    # Clone the fork on first activation (if not already present).
    # The dashboard needs a local checkout to read/write aeon.yml, skills/,
    # catalog/, etc. via its API routes.
    systemd.services.aeon-clone = {
      description = "Clone aeon fork for dashboard";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "aeon";
        Group = "aeon";
      };
      script = ''
        if [ ! -d /var/lib/aeon/agent/.git ]; then
          echo "Cloning ${repoSlug}..."
          ${pkgs.git}/bin/git clone https://github.com/${repoSlug}.git /var/lib/aeon/agent
        else
          echo "Repository already exists, skipping clone."
        fi
      '';
    };

    # Main dashboard service — runs `next dev` with the pre-installed deps.
    systemd.services.aeon = {
      description = "Aeon dashboard (autonomous agent framework)";
      after = [
        "network-online.target"
        "aeon-clone.service"
      ];
      wants = [
        "network-online.target"
        "aeon-clone.service"
      ];

      serviceConfig = {
        User = "aeon";
        Group = "aeon";
        WorkingDirectory = "/var/lib/aeon/agent/apps/dashboard";
        Restart = "on-failure";
        RestartSec = 5;
        Environment = [
          "NEXT_TELEMETRY_DISABLED=1"
          "AEON_REPO_ROOT=/var/lib/aeon/agent"
        ];
      };

      # Authenticate gh with the sops PAT, then start the dev server.
      # The dashboard's /api/* routes shell out to `gh` for every repo
      # operation (secrets, workflow dispatch, content reads), so this
      # must succeed before the server starts.
      preStart = ''
        ${pkgs.gh}/bin/gh auth login --with-token < ${cfg.ghTokenFile}
        ${pkgs.gh}/bin/gh repo set-default ${repoSlug}
      '';

      # Symlink the pre-built node_modules into the dashboard dir, then
      # run `next dev`. The --hostname/--port flags come from the module
      # options. NODE_PATH ensures `next` resolves from the nix package.
      script = ''
        ln -sfn ${cfg.package}/node_modules node_modules
        ${pkgs.nodejs}/bin/npx next dev --hostname ${cfg.host} --port ${toString cfg.port}
      '';
    };

    # Firewall
    networking.firewall.allowedTCPPorts = lib.optional cfg.exposeLan cfg.port;
  };
}
