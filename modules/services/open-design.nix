{
  config,
  lib,
  pkgs,
  ...
}:

# OpenDesign — local-first design product (daemon `od` + Next.js web frontend).
#
# Upstream retired its official Nix distribution on 2026-08-31
# (nexu-io/open-design@49cc5105), so the NixOS module is vendored here
# (./open-design-nixos.nix + ./open-design-common.nix, copied from the last
# shipping commit db9ebb7b) and the daemon/web packages are vendored under
# pkgs/open-design-*. flake.nix injects both packages through the closure
# module `openDesignPackagesModule`; this wrapper provides the
# `jupiter.services.openDesign` toggle so hosts opt in via the fleet's
# `jupiter.*` namespace, wiring sensible defaults for the serving host
# (callisto) while leaving fine-grained control to `services.open-design`
# when needed.
#
# Design artefacts are real files (HTML/PDF/PPTX/MP4) generated via agent
# skills; the daemon discovers agents via PATH scanning, so the service's
# PATH is widened to include the system profile where CLIs like
# `claude`/`codex`/`opencode` live (mirrors dsh.nix and opencode.nix).
#
# The web frontend is a static SPA that reverse-proxies /api/* to the
# daemon; by default it binds loopback only. Widen via
# `services.open-design.webFrontend.host` + `allowedOrigins` and
# `jupiter.services.openDesign.openFirewall` for LAN/tailnet exposure.
let
  cfg = config.jupiter.services.openDesign;
in
{
  imports = [ ./open-design-nixos.nix ];

  options.jupiter.services.openDesign = {
    enable = lib.mkEnableOption "OpenDesign — local-first design product (daemon `od` + web frontend)";

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open the daemon and web frontend ports in the firewall. Has no
        effect until `services.open-design.webFrontend.host` is widened
        from loopback (e.g. to `0.0.0.0`); the module asserts that
        `allowedOrigins` is set when the host is non-loopback so the
        daemon's same-origin gate does not 403 the SPA's writes.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/open-design";
      description = ''
        Directory holding the daemon's runtime state: SQLite database,
        per-project working trees, and saved artefacts. Mirrors
        `services.open-design.dataDir` default; override here to keep
        both layers in sync via the Jupiter option.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.open-design = {
      enable = true;
      autoStart = lib.mkDefault true;
      dataDir = cfg.dataDir;

      # The daemon scans PATH to discover agent CLIs. Systemd units
      # start with a minimal PATH; include the system profile and
      # per-user dirs so `claude`, `codex`, `opencode`, etc. are found
      # without per-host extraBinPaths. Operators needing custom locations
      # can still extend `services.open-design.extraBinPaths` directly —
      # this default is additive via mkDefault, not a forced value.
      extraBinPaths = lib.mkDefault [
        "/run/current-system/sw/bin"
        "/nix/var/nix/profiles/default/bin"
        "/etc/profiles/per-user/io/bin"
        "/home/io/.nix-profile/bin"
      ];

      # Run the static SPA alongside the daemon by default on the serving
      # host; callisto's cloudflare tunnel exposes it at
      # open-design.jupiter.au. Hosts that only need the headless API can
      # override with `services.open-design.webFrontend.enable = false`.
      webFrontend.enable = lib.mkDefault true;

      openFirewall = cfg.openFirewall;

      # Browser-backed features need a Chrome/Chromium the daemon can exec:
      #   - Design Browser / browser-use screenshots:
      #     apps/daemon/src/browser-sessions.ts looks for a system
      #     chrome/chromium on PATH, else OD_BROWSER_EXECUTABLE_PATH. None
      #     exists on callisto, so POST /api/projects/:id/browser-sessions
      #     returned 503 BROWSER_SESSION_START_FAILED.
      #   - HyperFrames HTML→MP4 render: the bundled hyperframes CLI spawns
      #     a puppeteer-controlled headless Chrome and resolves it through
      #     HYPERFRAMES_BROWSER_PATH (config.chromePath →
      #     PRODUCER_HEADLESS_SHELL_PATH → HYPERFRAMES_BROWSER_PATH →
      #     ~/.cache/hyperframes → ~/.cache/puppeteer). None existed, so
      #     every render failed at browser resolution.
      # Point both at the fleet nixpkgs chromium. Note: pixel screenshot
      # EXPORT (PNG/PDF/PPTX via the desktop Electron renderer) remains
      # unavailable in a headless deployment — that path has no browser
      # fallback.
      extraEnv = {
        OD_BROWSER_EXECUTABLE_PATH = "${pkgs.chromium}/bin/chromium";
        HYPERFRAMES_BROWSER_PATH = "${pkgs.chromium}/bin/chromium";
      };
    };

    # Upstream's nixos module sets `systemd.services.open-design.environment.PATH`
    # with normal priority, which conflicts with systemd's own default PATH
    # (coreutils) at the same priority when the host's nixpkgs is the fleet
    # pin rather than the upstream pin. Force the merged value so the host
    # evaluates — mirrors the `environment.PATH = lib.mkForce ...` pattern in
    # opencode-web.nix and avoids the "conflicting definition values" error
    # that breaks `nix flake check` on callisto once open-design is imported.
    systemd.services.open-design.environment.PATH = lib.mkForce (
      lib.concatStringsSep ":" (
        [
          "/run/wrappers/bin"
          "/run/current-system/sw/bin"
          "/nix/var/nix/profiles/default/bin"
          "/usr/local/bin"
          "/usr/bin"
          "/bin"
        ]
        ++ config.services.open-design.extraBinPaths
      )
    );

    # The daemon's PATH-discovered agents (opencode, claude, codex) inherit
    # the service environment, so the model-router provider
    # (router.jupiter.au — the fleet's own gateway) resolves inside
    # spawned opencode sessions the same way the interactive rig does:
    # EnvironmentFile carries MODEL_ROUTER_TOKEN (plus the provider keys
    # opencode's {env:} references need) straight into the unit.
    systemd.services.open-design.serviceConfig.EnvironmentFile = lib.mkIf (
      config.sops.secrets ? dsh_env
    ) [ config.sops.secrets.dsh_env.path ];

    # The upstream unit runs as `io` on callisto but nothing provisions the
    # data dir for that user — a directory first created under a different
    # owner (observed 2026-09-01: root-owned, EACCES crash-loop, 130+
    # restarts; again 2026-09-06: open-design:open-design 0750, preStart
    # chown failing with EACCES) wedges the daemon forever. Re-assert
    # ownership on every start so whichever way upstream moves the service
    # user, the dir follows. This MUST be a root-run (`+`-prefixed)
    # ExecStartPre, not preStart: preStart runs as the *service user*,
    # which can never chown (and can't even read a 0750 dir owned by
    # someone else). Owner is read from the unit's own configured
    # User/Group so host overrides (callisto: io/users) are honoured.
    systemd.services.open-design.preStart = lib.mkForce "";
    systemd.services.open-design.serviceConfig.ExecStartPre = [
      "+${
        pkgs.writeShellScript "open-design-fix-datadir" ''
          mkdir -p ${cfg.dataDir}
          chown -R ${config.systemd.services.open-design.serviceConfig.User}:${config.systemd.services.open-design.serviceConfig.Group or "users"} ${cfg.dataDir}
          chmod 750 ${cfg.dataDir}
        ''
      }"
    ];
  };
}
