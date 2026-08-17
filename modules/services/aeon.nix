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
  # node_modules + source for `next dev`. Built from `source` when the
  # flake injects its pinned aeon input (see flake.nix's aeonModule); the
  # null fallback inside the package floats on fetchFromGitHub main, which
  # is why the flake always injects.
  aeonPkg = pkgs.callPackage ../../pkgs/aeon/default.nix {
    src = cfg.source;
  };

  # Derive owner/repo from the repoUrl for gh repo set-default + clone
  # repoUrl format: "github:owner/repo"
  repoSlug = lib.removePrefix "github:" cfg.repoUrl;
in
{
  options.jupiter.services.aeon = {
    enable = lib.mkEnableOption "Aeon dashboard (autonomous agent framework web UI)";

    # Plain mkOption, NOT `mkPackageOption pkgs "aeon-dashboard" { } //
    # { default = ...; }`: mkPackageOption eagerly evaluates
    # `pkgs.aeon-dashboard or ...` at option-declaration time, so the `//`
    # trick only *looks* lazy — if pkgs.aeon-dashboard ever appears (or the
    # attrpath's intermediates error), the two defaults fight. The dashboard
    # is not in nixpkgs and never will be; name it explicitly.
    package = lib.mkOption {
      type = lib.types.package;
      default = aeonPkg.dashboard;
      defaultText = "pkgs/aeon/default.nix: dashboard";
      description = "Aeon dashboard package (node_modules + source for next dev).";
    };

    # Pinned upstream source (the flake's `aeon` input, injected via
    # flake.nix's aeonModule — same lexical-closure pattern as sunoWebModule).
    # Kept as an option so the module stays a plain NixOS module.
    source = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Pinned aeon source tree. null falls back to the package's internal
        fetchFromGitHub of main (floating — NOT what the fleet runs); the
        flake always sets this to its locked input.
      '';
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
      default = "127.0.0.1";
      description = ''
        Address the dashboard binds. Loopback by default: this UI wields a
        GitHub PAT with repo scope (workflow dispatch, secrets writes), so it
        must not be reachable from the LAN. Remote access goes through the
        tailscale tunnel (100.x.y.z still works: set host to the tailscale IP
        or 0.0.0.0 ONLY on a host whose firewall is already tailnet-scoped).
      '';
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
      # Without wantedBy the unit is only `linked`, not pulled into any target,
      # so it never runs at boot — `enable` defines it but wires nothing.
      wantedBy = [ "multi-user.target" ];
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
      # Without wantedBy the unit is only `linked`, not pulled into any target,
      # so it never runs at boot — `enable` defines it but wires nothing.
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "aeon-clone.service"
      ];
      wants = [
        "network-online.target"
        "aeon-clone.service"
      ];

      # The dashboard's API routes shell out to these by BARE NAME at request
      # time (child_process exec/spawn), so they have to be on the unit's PATH
      # — absolute store paths in preStart/script don't help those callers:
      #   gh    — 14 call sites (secrets, workflow dispatch, run list, content)
      #   git   — lib/sync.ts + /api/outputs (stash/pull the fork checkout)
      #   gnutar+gzip — `tar czf -` packs harness OAuth creds into gh secrets
      #                 (GNU tar execs gzip for `z`)
      #   nodejs — node_modules/.bin/next is a `#!/usr/bin/env node` shim
      # Without this the unit gets systemd's default PATH (coreutils, findutils,
      # gnugrep, gnused, systemd) and every one of those calls ENOENTs.
      path = [
        pkgs.gh
        pkgs.git
        pkgs.gnutar
        pkgs.gzip
        pkgs.nodejs
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
      # `gh` writes its config under $HOME/.config/gh — systemd sets HOME from
      # the aeon user's passwd entry (/var/lib/aeon), which the tmpfiles rule
      # below creates. `gh auth setup-git` is deliberately NOT run: the
      # dashboard only ever reads over git (stash/pull of a public repo) and
      # does every write through `gh` itself, which carries its own auth.
      preStart = ''
        gh auth login --with-token < ${cfg.ghTokenFile}
        gh repo set-default ${repoSlug}
      '';

      # gh token persistence: gh stores the authenticated session in
      # ~/.config/gh/hosts.yml (plaintext, mode 0600). /var/lib/aeon is NOT
      # wiped between runs, so the PAT-equivalent session survives unit
      # stops — treat /var/lib/aeon as credential-bearing state (it also
      # holds the fork clone + harness OAuth creds packed by tar). The
      # preStart re-login refreshes it each start; it is never revoked.
      #
      # Symlink the pre-built node_modules into the checkout, then run `next
      # dev` against the checkout's own source. `next` is invoked by its store
      # path rather than through `npx`, which would otherwise be free to reach
      # out to the network if local resolution ever missed.
      #
      # --webpack, not Turbopack (the Next 16 default): Turbopack's Filesystem
      # Root sandbox refuses the node_modules symlink above because its target
      # is in /nix/store, outside the project root — fatal "Symlink [project]
      # /node_modules is invalid, it points out of the filesystem root". This
      # is a documented known gap (nextjs.org/docs/app/api-reference/turbopack
      # §Filesystem Root); webpack follows the store symlink fine. Confirmed
      # locally 2026-08-14. Revisit only if the dashboard needs Turbopack's
      # dev speed (it doesn't — it's a low-traffic internal UI).
      script = ''
        ln -sfn ${cfg.package}/node_modules node_modules
        exec ${cfg.package}/node_modules/.bin/next dev --webpack \
          --hostname ${cfg.host} --port ${toString cfg.port}
      '';
    };

    # Firewall
    networking.firewall.allowedTCPPorts = lib.optional cfg.exposeLan cfg.port;
  };
}
