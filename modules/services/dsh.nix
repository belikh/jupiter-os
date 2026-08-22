{
  config,
  lib,
  pkgs,
  ...
}:

# DeepSeek Harness (`dsh`) — DeepSeek AI's open-source agent harness
# (github.com/deepseek-ai/deepseek-harness), packaged from the published
# npm tarball in pkgs/dsh. This module runs its Web UI profile as a
# systemd service: `dsh web` boots the auto-initialized `web` profile
# (base + web-app bundles, no pnpm needed for the shipped stack) and
# serves the browser UI used to drive the agent.
#
# Deliberate deviation from the nom-web "0.0.0.0 + firewall" pattern,
# measured against 0.1.0-rc.6 (guard re-checked at 0.1.0-rc.8): the web
# app's config schema only accepts host "127.0.0.1" | "0.0.0.0", and the
# CLI additionally rejects 0.0.0.0 with "intentionally not supported yet
# for safety: it would expose remote code execution to the network". The
# rc.8 bundle no longer ships that literal string but keeps the
# PRIVILEGED_METHODS loopback gate on the settings/credentials plane (in
# dsh-client-connection) — the load-bearing guard. The Web UI is therefore
# LOOPBACK-ONLY — reach it through an SSH tunnel:
#   ssh -L 3080:127.0.0.1:3080 root@<host>   →   http://localhost:3080
# If a later dsh relaxes the guard, `host` + `trustedHosts` below are the
# knobs to widen access (the /api browser-trust fence keys on the Host
# header, so every name/IP the UI is reached by must be a trusted host).
# Do NOT paper over the guard with a LAN TCP forwarder without deciding,
# explicitly, that the LAN trust model covers an unauthenticated agent
# harness with workspace-write.
#
# First-use notes (nothing secret at build/activation time):
#   - A DeepSeek API key is entered in the UI (Settings → Models) on first
#     use; it persists under dataDir (DSH_HOME/.credentials.yaml).
#   - Out-of-tree plugins are managed with `dsh plugin --profile web add …`,
#     which forwards to pnpm — hence pnpm on the unit's PATH and in
#     systemPackages (git-hosted plugin specs additionally need git).
#   - The invoking directory is the default workspace root; the service
#     runs from dataDir/workspace, which the Web UI offers as the default
#     workspace choice.
let
  cfg = config.jupiter.services.dsh;

  dshPkg = pkgs.callPackage ../../pkgs/dsh { };

  # Git credential helper for github.com: answers git's credential request
  # with the GitHub token from ghTokenFile, so `git push` over HTTPS works
  # from the agent shell. The username is arbitrary for token auth (GitHub
  # ignores it); "x-access-token" is the conventional marker and works for
  # fine-grained PATs. Only referenced (lazily) when ghTokenFile is set.
  gitCredentialHelper = pkgs.writeShellScript "git-credential-github" ''
    printf 'username=x-access-token\npassword=%s\n' "$(cat ${cfg.ghTokenFile})"
  '';

  # The dsh user's ~/.gitconfig: point git at the credential helper above.
  # Written to <dataDir>/.gitconfig (the dsh home) by a tmpfiles rule.
  gitConfig = pkgs.writeText "dsh-gitconfig" ''
    [credential]
        helper = ${lib.getExe gitCredentialHelper}
  '';
in
{
  options.jupiter.services.dsh = {
    enable = lib.mkEnableOption "DeepSeek Harness (dsh) web UI";

    # Plain mkOption, NOT `mkPackageOption pkgs "dsh" { } // { default = …; }`:
    # the `//` trick only looks lazy and eagerly evaluates pkgs.dsh, masking
    # a nonexistent attr. dsh is not in nixpkgs; name the in-tree package.
    package = lib.mkOption {
      type = lib.types.package;
      default = dshPkg;
      defaultText = "pkgs/dsh";
      description = "dsh package to run.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3080;
      description = "TCP port the web UI listens on.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Address the web app binds. As of 0.1.0-rc.6 the schema only
        accepts "127.0.0.1" | "0.0.0.0" and the CLI rejects 0.0.0.0 as a
        deliberate safety guard — loopback is the only working value.
        Anything else crash-loops the service at boot.
      '';
    };

    trustedHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Hosts/IPs accepted by dsh's /api browser-trust fence. Every name
        or IP the UI will be reached by from a browser must be listed.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/dsh";
      description = ''
        State directory (DSH_HOME): profiles, plugins, credentials and
        the default workspace live under here.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open `port` in the firewall (intended for the trusted LAN).";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Environment file (e.g. a sops secret) exported into the service.
        dsh resolves provider credentials from the process environment by
        NAME — a provider profile in settingsFile references e.g.
        `apiKeyEnv: GROQ_API_KEY`, and this file supplies the value.
      '';
    };

    settingsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        YAML file copied to `$DSH_HOME/settings.yaml` on activation, ONLY
        if the file does not already exist (the app owns it afterwards and
        rewrites it on settings changes — provisioning never clobbers).
        Holds host-side dsh settings, e.g. the `llm-pi-ai:` provider
        profiles for non-DeepSeek OpenAI-compatible endpoints. Contains
        credential NAMES, never values — keys come from environmentFile.
        Nix store paths are world-readable for exactly that reason.
      '';
    };

    ghTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a file holding a GitHub token used to authenticate
        <literal>git push</literal> from the agent shell (e.g.
        <literal>config.sops.secrets.aeon_gh_token.path</literal>). When
        set, the module installs a git credential helper and a
        <literal>.gitconfig</literal> for the dsh user so HTTPS pushes to
        github.com authenticate with it. The token file must be readable by
        the <literal>dsh</literal> user (shared group + 0440, or a
        dedicated dsh-owned sops secret). Leave null to skip git-push auth
        (public pulls still work).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Dedicated user — the harness agent runs bash against its workspace;
    # it should not run as root.
    users.users.dsh = {
      isSystemUser = true;
      group = "dsh";
      home = cfg.dataDir;
      createHome = true;
    };
    users.groups.dsh = { };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 dsh dsh - -"
      "d ${cfg.dataDir}/workspace 0750 dsh dsh - -"
    ]
    ++ lib.optionals (cfg.ghTokenFile != null) [
      # ~/.gitconfig -> credential.helper reads the GitHub token, so the
      # agent's `git push` authenticates without a credential prompt.
      "C+ ${cfg.dataDir}/.gitconfig 0640 dsh dsh - ${gitConfig}"
    ]
    ++ lib.optional (
      cfg.settingsFile != null
    ) "C+ ${cfg.dataDir}/settings.yaml 0640 dsh dsh - ${cfg.settingsFile}";

    systemd.services.dsh = {
      description = "DeepSeek Harness (dsh) web UI";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      # `dsh plugin` forwards to pnpm; git-hosted plugin specs need git;
      # the agent's own bash tool and any spawned node scripts need bash +
      # node. systemd's default PATH only carries coreutils-class tools, so
      # the extra binaries below are explicit.
      #
      # The agent's model-facing bash tool inherits THIS unit's PATH as its
      # spawn base (dsh-subprocess's childEnv starts from the scrubbed parent
      # env), so anything the agent shell needs must be reachable here. Without
      # the system-wide entry below the agent shell can NOT run `ssh`/`scp`/
      # `sftp`, `curl`, `awk`, `diff`, `ps`, `gpg`, … — those all live only
      # under /run/current-system/sw/bin (the NixOS system package set from
      # environment.systemPackages) and were missing from agent commands
      # ("ssh: command not found", fixed 2026-08-19).
      #
      # `/run/current-system/sw` is the active system-path symlink; adding it
      # puts every currently-installed systemPackage tool on the unit PATH (and
      # therefore in the agent shell) without enumerating them — anything added
      # to environment.systemPackages later shows up there too. It comes FIRST
      # so the system-wide `ssh`/`curl`/`awk`/… win over any shadowing, while
      # the harness's own nodejs (NOT in systemPackages) still resolves from
      # pkgs.nodejs below.
      path = [
        "/run/current-system/sw"
        pkgs.bash
        pkgs.git
        pkgs.pnpm
        pkgs.nodejs
      ];

      environment = {
        DSH_HOME = cfg.dataDir;
      };

      serviceConfig = {
        Type = "exec";
        User = "dsh";
        Group = "dsh";
        WorkingDirectory = "${cfg.dataDir}/workspace";
        Restart = "on-failure";
        RestartSec = "5s";

        # The agent writes its workspace, profiles and credentials under
        # dataDir; node's V8 JIT needs writable+executable memory, and the
        # harness's own bash confinement may create namespaces, so those
        # hardening knobs are deliberately left off.
        ReadWritePaths = [ cfg.dataDir ];
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        LockPersonality = true;
      }
      // (lib.optionalAttrs (cfg.environmentFile != null) {
        EnvironmentFile = [ cfg.environmentFile ];
      });

      # Launcher grammar: `dsh web` == `dsh --profile web`; everything after
      # is handed to the web app, which owns --host/--port/--trusted-host.
      script = ''
        exec ${lib.getExe cfg.package} web \
          --host ${lib.escapeShellArg cfg.host} \
          --port ${toString cfg.port} \
          ${lib.concatMapStrings (h: "--trusted-host ${lib.escapeShellArg h} ") cfg.trustedHosts}
      '';
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

    # Interactive CLI on the host (sshes in, or `sudo -u dsh dsh …`), plus
    # pnpm so `dsh plugin … add` works outside the unit too.
    environment.systemPackages = [
      cfg.package
      pkgs.pnpm
    ];
  };
}
