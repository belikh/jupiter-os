{
  config,
  lib,
  pkgs,
  ...
}:

# Intel/DMTF Device Management Toolkit — "Console" component
# (https://github.com/device-management-toolkit/console). The out-of-band AMT
# management API server: a Go HTTP service backed by an embedded SQLite store,
# no external database required (provider=sqlite, see internal/app/repos.go).
#
# Built HEADLESS — the `-tags=noui` build constraint strips the embedded web UI
# (see cmd/app/edition_noui.go), matching this fleet's appliance-style hosts.
# A headless binary serves the API only; set `externalUiUrl` to redirect the
# few UI routes at a separately-hosted frontend, or leave it empty for pure
# API-only mode (UI requests 404). A full-UI binary would need a separate
# derivation (and node at build time) and isn't produced here.
#
# The same package is also exposed standalone as the flake output
# `packages.x86_64-linux.dmt-console` (built with the UNTUNED nixpkgs so it
# substitutes from cache.nixos.org and never lands in europa's gccarch-bdver4
# closure). Keep these two buildGoModule calls in sync.

let
  cfg = config.jupiter.services.dmtConsole;

  # Pinned upstream rev (shallow clone HEAD at packaging time). The src +
  # vendor hashes are real (computed via the build-fail loop, not fakes) —
  # see the REPORT note in the commit that added this module. CGO is left
  # disabled (buildGoModule default); the SQLite driver is modernc.org/sqlite
  # (pure Go), so the result is a fully static binary.
  dmtConsole = pkgs.buildGoModule {
    pname = "dmt-console";
    version = "unstable-2026-07-22";
    src = pkgs.fetchFromGitHub {
      owner = "device-management-toolkit";
      repo = "console";
      rev = "6bf3e82636ec226a0e7f7eb048c9161a9e93d348";
      hash = "sha256-CzwIDXpGWWrwIleIoQrCbJ+fquPn9auqLiWD7G0afnM=";
    };
    vendorHash = "sha256-3G7FypfAVwcfFWmqu1TX5EDpZ4hhdZ2HyKQYUTTwlmY=";
    subPackages = [ "cmd/app" ];
    # Headless build: strips embedded web UI assets (cmd/app/edition_noui.go).
    tags = [ "noui" ];
    # CGO is left at buildGoModule's default. Upstream's Dockerfile builds
    # fully static (CGO_ENABLED=0 -> scratch image); this nixpkgs buildGoModule
    # pins CGO_ENABLED=1 in its `env` and rejects a plain override, so the
    # resulting binary is dynamically linked to the nix glibc (libresolv/
    # libpthread). That is fine under NixOS — glibc is always present — and
    # modernc.org/sqlite stays pure-Go either way. A truly static build would
    # need `.overrideAttrs (old: { env = old.env // { CGO_ENABLED = 0; }; })`,
    # deferred since it's cosmetic for an appliance that doesn't ship a
    # container image.
    ldflags = [
      "-s"
      "-w"
    ];
    # buildGoModule names the binary after its subpackage dir (`app`); rename
    # to the project's conventional `console` so ExecStart and `nix build
    # .#dmt-console` produce an intuitive result/bin/console.
    postInstall = ''
      mv $out/bin/app $out/bin/console
    '';
  };

  # Structural (non-secret) configuration, generated via pkgs.formats.yaml so
  # the field nesting (http.allowed_origins / allowed_headers under `http`,
  # not top-level) and string-valued scalars (`port` is a Go string, must stay
  # quoted so yaml.v2 doesn't coerce it to an int) come out right. Secrets are
  # deliberately NOT here: cleanenv overlays environment variables on top of
  # this file, so AUTH_ADMIN_PASSWORD / AUTH_JWT_KEY / APP_ENCRYPTION_KEY come
  # in via the systemd EnvironmentFile (a sops-managed env file). That also
  # avoids the app's first-run write-back of a generated admin password — it
  # targets the config file, which is read-only here, and would fatal-exit.
  # Supplying AUTH_ADMIN_PASSWORD makes cmd/app/main.go's handleAdminPassword
  # return early before any write (see main.go:304-307).
  configFormat = pkgs.formats.yaml { };
  configFile = configFormat.generate "dmt-console-config.yml" {
    app = {
      name = "console";
      repo = "device-management-toolkit/console";
      # common_name is the CN for the runtime-generated CIRA/cert bundle; only
      # matters when CIRA is enabled (disabled by default below).
      common_name = cfg.commonName;
      disable_cira = cfg.disableCIRA;
    };
    http = {
      host = cfg.host;
      # Quoted by the YAML generator — config.HTTP.Port is a Go string.
      port = toString cfg.port;
      ws_compression = cfg.wsCompression;
      tls = {
        # enabled=true + empty cert/key => self-signed generated at runtime
        # (needs a writable cert dir). Default false so plain HTTP serves on
        # the trusted LAN without that machinery.
        enabled = cfg.tlsEnabled;
        certFile = "";
        keyFile = "";
      };
      allowed_origins = cfg.allowedOrigins;
      allowed_headers = cfg.allowedHeaders;
    };
    logger.log_level = cfg.logLevel;
    secrets = {
      # Vault is optional: an empty token means handleSecretsConfig returns
      # not-configured and the app falls back to APP_ENCRYPTION_KEY from the
      # env (which the EnvironmentFile must supply).
      address = "http://localhost:8200";
      token = "";
      path = "secret/data/console";
    };
    # NOTE: the yaml key is `postgres` even for SQLite — see config.DB.
    postgres = {
      provider = "sqlite";
      pool_max = 2;
    };
    ea = {
      # Enterprise Assistant is optional; empty => unused.
      url = "http://localhost:8000";
      username = "";
      password = "";
    };
    auth = {
      disabled = false;
      adminUsername = "standalone";
      # Placeholder; the real key arrives via AUTH_JWT_KEY env. The upstream
      # default satisfies cleanenv's env-required check until overridden.
      jwtKey = "your_secret_jwt_key";
    };
    ui = {
      # Only read by headless (noui) builds: when set, UI routes redirect here;
      # empty => API-only (UI requests 404).
      externalUrl = cfg.externalUiUrl;
    };
  };
in
{
  options.jupiter.services.dmtConsole = {
    enable = lib.mkEnableOption "the DMT Console (Intel AMT management API, headless)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8181;
      description = "TCP port the Console HTTP API listens on (upstream default 8181).";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Network address to bind. Empty or 0.0.0.0 binds all interfaces.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the Console port in the firewall (intended for the trusted LAN).";
    };

    tlsEnabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable HTTPS. Upstream defaults to true with a runtime self-signed
        cert; we default to false so the trusted-LAN service serves plain HTTP
        without provisioning a writable certificate directory. The `--health`
        probe honours HTTP_TLS_ENABLED (set from this), so it stays consistent
        with the listener scheme.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/dmt-console";
      description = ''
        Persistent state root. The embedded SQLite file lands at
        `<dataDir>/device-management-toolkit/console.db` — both the migration
        runner (internal/app/migrate.go) and the runtime pool (pkg/db/sql.go)
        anchor on `os.UserConfigDir()`, which we point at `dataDir` via
        XDG_CONFIG_HOME.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "config.sops.secrets.dmt_console_env.path";
      description = ''
        Path to an environment file (KEY=VALUE) supplying the secrets cleanenv
        overlays on the read-only config. Must define at least:

          AUTH_ADMIN_PASSWORD   — admin login password (avoids the first-run
                                  write-back that would target the read-only
                                  nix-store config and fatal-exit).
          AUTH_JWT_KEY          — JWT signing key (upstream default is a known
                                  insecure placeholder).
          APP_ENCRYPTION_KEY    — DB/symmetric encryption key (without it the
                                  app tries an interactive keyring prompt and
                                  refuses to start under systemd).

        Wire it from sops the way modules/services/attic-server.nix does:
          sops.secrets.dmt_console_env = { };
          jupiter.services.dmtConsole.environmentFile =
            config.sops.secrets.dmt_console_env.path;
      '';
    };

    externalUiUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "https://ui.example.com";
      description = ''
        Headless-build UI redirect target. Empty (default) = API-only mode
        (UI routes 404). Set to a separately-hosted frontend to redirect UI
        requests. Only affects `noui` builds, which is what this module ships.
      '';
    };

    disableCIRA = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Disable CIRA (Client Initiated Remote Access). CIRA needs the MPS relay
        and a certificate bundle; defaulting off matches a standalone API-only
        deploy. DisableCIRA=true short-circuits setupCIRACertificates in
        cmd/app/main.go so no cert material is generated at startup.
      '';
    };

    commonName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "Certificate common name; only relevant when CIRA is enabled.";
    };

    logLevel = lib.mkOption {
      type = lib.types.str;
      default = "info";
      description = "Zerolog level (debug/info/warn/error/fatal/panic/no/trace/disabled).";
    };

    allowedOrigins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "*" ];
      description = "CORS allowed origins (gin-contrib/cors).";
    };

    allowedHeaders = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "*" ];
      description = "CORS allowed headers (gin-contrib/cors).";
    };

    wsCompression = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable permessage-deflate WebSocket compression.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Guard against the silent footgun: without AUTH_ADMIN_PASSWORD the app
    # generates one, tries to persist it to the read-only nix-store config, and
    # fatal-exits ("Refusing to start with an unsaved credential"). Require the
    # operator to wire an environmentFile.
    assertions = [
      {
        assertion = cfg.environmentFile != null;
        message = ''
          jupiter.services.dmtConsole is enabled without `environmentFile`.
          The Console refuses to start without AUTH_ADMIN_PASSWORD supplied
          via env (it cannot write a generated one back to the read-only
          config). Point `environmentFile` at a sops env file providing
          AUTH_ADMIN_PASSWORD, AUTH_JWT_KEY and APP_ENCRYPTION_KEY.
        '';
      }
    ];

    systemd.services.dmt-console = {
      description = "DMT Console — Intel AMT management API (headless)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      # Structural env the binary reads directly (secrets arrive via
      # EnvironmentFile below, which overlays these without leaking to the
      # unit's Environment= line in `systemctl show`).
      environment = {
        HTTP_PORT = toString cfg.port;
        # The --health probe (cmd/app/health.go) picks scheme from this so it
        # matches the listener; config.HTTP.TLS.Enabled reads the same value.
        HTTP_TLS_ENABLED = lib.boolToString cfg.tlsEnabled;
        # Anchors both the SQLite path (pkg/db/sql.go setupEmbeddedDB) and
        # config resolution on the persistent state dir instead of a
        # DynamicUser's ephemeral $HOME.
        XDG_CONFIG_HOME = cfg.dataDir;
      };

      serviceConfig = {
        ExecStart = "${dmtConsole}/bin/console --config ${configFile}";
        EnvironmentFile = cfg.environmentFile;
        DynamicUser = true;
        StateDirectory = "dmt-console";
        Restart = "on-failure";
        RestartSec = "5s";

        # Hardening. Conservative set only — this module has not yet been
        # runtime-validated on a live host (no host enables it), so the
        # riskier knobs (SystemCallFilter, RestrictAddressFamilies,
        # MemoryDenyWriteExecute) are intentionally omitted: a service that
        # starts is worth more than one that's locked down but untested-dead.
        # Tighten when first enabling on a real machine.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
        CapabilityBoundingSet = [ "" ];
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
