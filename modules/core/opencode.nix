{
  config,
  lib,
  pkgs,
  ...
}:

# opencode (PINNED 1.18.22 — the last V1) agent rig — the remote coding-agent
# harness on the serving host, migrated off io's laptop (2026-08-24 planning
# session, docs/plans/2026-08-24-001-callisto-opencode-rig-deployment.md).
#
# Three pieces:
#   1. `opencode-wrapped` launcher: exports provider keys from sops secrets
#      into the environment, then execs the PER-USER binary at
#      ~/.opencode/bin/opencode (installed by the official installer as io).
#      That binary is pinned to 1.18.22 by an activation script and then made
#      non-writable (chmod 0555) so its built-in self-updater CANNOT rewrite
#      it. Without that guard it silently drifted to V2 1.18.23 on 2026-08-26
#      and broke remote-opencode 1.5.3's serve lifecycle (the Discord bridge
#      started hanging on "Waiting for OpenCode server..."). 1.18.22 is the
#      immediate predecessor of the V2 bump and is what the rig was proven on.
#      Deliberately NOT a nixpkgs package: opencode's plugin host and the
#      pinned-user layout assume ~/.opencode/bin, and V2 must stay out until
#      plugin-API parity.
#   2. ONE canonical /home/io/.config/opencode/opencode.json,
#      activation-installed from the Nix store on every switch (crush.nix
#      pattern) — local edits made through the TUI are re-synced away, so
#      the committed config always wins. Contents follow the remediation
#      program in research report opencode-config-improve-1c323b §4:
#      pinned model routing, permission lockdown, task-deny globs for the
#      ultracode subagents, single MCP chokepoint.
#   3. sops secret declarations. zai_api_key/groq_api_key match crush.nix's
#      entries verbatim (identical attrs merge cleanly when both modules
#      are enabled). OPENCODE_API_KEY is NOT its own secret: it is sed-
#      extracted from the packed dsh_env env file, which callisto already
#      provisions — widened there to group users/0440 so io can read it.
#
# Model ids verified against live catalogs 2026-08-25, re-verified 2026-08-26:
# `opencode models` on 1.18.x + the opencode zen gateway's /models + dsh
# settingsFile spelling all agree on glm-5.3, kimi-k2.7-code, minimax-m3.
# groq rotated its catalog under us on 2026-08-26 — llama-3.1-8b-instant
# vanished from this key's /models; title-gen now rides openai/gpt-oss-20b.
let
  cfg = config.jupiter.core.opencode;

  # THE canonical config (see module header). Comments live here, not in
  # the JSON. The watcher key was schema-probed against 1.18.22
  # (`opencode debug config` drops unknown keys but resolves this one).
  builtinConfig = pkgs.writeText "opencode.json" (
    builtins.toJSON {
      "$schema" = "https://opencode.ai/config.json";
      # Pinned routing: big model for work, groq instant for title-gen
      # (closes the main-model title-gen leak on this box). small_model
      # rotated 2026-08-26: groq dropped llama-3.1-8b-instant from this
      # key's live catalog ("does not exist or you do not have access"),
      # gpt-oss-20b is the verified replacement (live /models + dsh's
      # field-proven limits table).
      model = "zai-coding/glm-5.3";
      small_model = "groq/openai/gpt-oss-20b";
      # V1 construct; required by open-ultracode. Inert on V2 (Phase 2).
      subagent_depth = 2;
      watcher = {
        ignore = [
          "**/node_modules/**"
          "**/.git/**"
          "**/research/raw/**"
        ];
      };
      # Permission posture — io's explicit call 2026-08-26: wide open, same
      # as the proven laptop rig ("never needs permission for anything").
      # The plan §4b ask-gate lockdown is superseded: this rig is driven
      # headless via the Discord bridge, where any ask/deny prompt deadlocks
      # the session forever (observed live: external_directory=ask hung a
      # build-agent thread on ~/.config/opencode). io accepts the tradeoff
      # on a serving host; git pushes are still reviewed post-hoc by io.
      permission = "allow";
      provider = {
        # Same endpoint/account as dsh settingsFile + crush.json; keys come
        # from the environment the wrapper exports (never stored in JSON).
        "zai-coding" = {
          npm = "@ai-sdk/openai-compatible";
          name = "Z.AI coding plan";
          options = {
            baseURL = "https://api.z.ai/api/coding/paas/v4";
            apiKey = "{env:Z_AI_API_KEY}";
          };
          models = {
            "glm-5.3" = {
              limit = {
                context = 1000000;
                output = 131072;
              };
            };
          };
        };
        groq = {
          npm = "@ai-sdk/openai-compatible";
          name = "Groq";
          options = {
            baseURL = "https://api.groq.com/openai/v1";
            apiKey = "{env:GROQ_API_KEY}";
          };
          models = {
            "openai/gpt-oss-20b" = {
              limit = {
                context = 131072;
                output = 65536;
              };
            };
          };
        };
        opencode-go = {
          npm = "@ai-sdk/openai-compatible";
          name = "OpenCode Go";
          options = {
            baseURL = "https://opencode.ai/zen/go/v1";
            apiKey = "{env:OPENCODE_API_KEY}";
          };
          models = {
            "kimi-k2.7-code" = {
              limit = {
                context = 262144;
                output = 262144;
              };
            };
            "minimax-m3" = {
              limit = {
                context = 1000000;
                output = 131072;
              };
            };
          };
        };
      };
      mcp.cloudflare = {
        type = "remote";
        url = "https://mcp.cloudflare.com/mcp";
      };
      # Local plugin as a file:/// URI — the form the proven laptop rig
      # runs on this same 1.18.x series; bare store paths are unproven.
      plugin = [
        "file:///home/io/.local/share/open-ultracode/.opencode/plugins/open-ultracode.ts"
        "@parallel-web/opencode-plugin"
      ];
    }
  );

  # Keys enter the environment only here — never in any file on disk.
  # dsh_env packs KEY=value lines; sed pulls just the one we need.
  # The browser-lane pair (WP7-lite) has no consumer yet — upstream
  # belikh/hyperresearch-opencode#2 lights it up when it merges.
  opencode-wrapped = pkgs.writeShellScriptBin "opencode" ''
    export Z_AI_API_KEY="$(cat ${config.sops.secrets.zai_api_key.path})"
    export GROQ_API_KEY="$(cat ${config.sops.secrets.groq_api_key.path})"
    export OPENCODE_API_KEY="$(sed -n 's/^OPENCODE_API_KEY=//p' ${config.sops.secrets.dsh_env.path})"
    export CLOUDFLARE_BROWSER_RUN_TOKEN="$(cat ${config.sops.secrets.cloudflare_browser_run_token.path})"
    export CF_ACCOUNT_ID="19f62c2ef7861336d274166233ba3a17"
    exec "$HOME/.opencode/bin/opencode" "$@"
  '';
in
{
  options.jupiter.core.opencode = {
    enable = lib.mkEnableOption ''
      opencode agent rig: sops-keyed wrapped launcher + activation-installed
      canonical config. Requires the per-user binary at ~/.opencode/bin/opencode
      (official installer, pinned to 1.18.22 and locked non-writable).
    '';
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ opencode-wrapped ];

    # The installer binary at ~/.opencode/bin/opencode is upstream's
    # dynamically-linked generic-Linux build (needs only libc/libm/pthread/
    # dl per its NEEDED list). nix-ld provides the /lib64 loader stub +
    # NIX_LD_LIBRARY_PATH session vars that make such binaries run on
    # NixOS; the module default library set covers it.
    programs.nix-ld.enable = true;

    sops.secrets.zai_api_key = {
      owner = "io";
      mode = "0400";
    };

    sops.secrets.groq_api_key = {
      owner = "io";
      mode = "0400";
    };

    # Browser-lane prep (WP7-lite): random token generated blind into sops
    # (never displayed); consumed only when upstream issue #2 merges.
    sops.secrets.cloudflare_browser_run_token = {
      owner = "io";
      mode = "0400";
    };

    # ~/.config is already persisted for io where impermanence applies;
    # callisto runs plain ext4. Re-synced on every activation, so the
    # committed config always wins over edits made through the TUI.
    system.activationScripts.opencodeConfig = lib.stringAfter [ "users" ] ''
      install -D -m 0644 -o io -g users ${builtinConfig} /home/io/.config/opencode/opencode.json
    '';

    # Pin the per-user opencode binary to 1.18.22 (last V1) and LOCK it with
    # chmod 0555 so the self-updater can't silently drift to V2 again — that
    # drift on 2026-08-26 broke the Discord bridge's serve readiness. The
    # installer resolves the exact asset for --version; the marker guards
    # against re-downloading on every switch. Activation runs as root, so we
    # set HOME=/home/io for the installer (it targets $HOME/.opencode) and fix
    # ownership afterward; 0555 (owner non-writable) is the real guard — the
    # updater replaces the binary in place, which 0555 blocks. `su` is avoided
    # because activation has no tty.
    system.activationScripts.opencodeBinary = lib.stringAfter [ "users" "opencodeConfig" ] ''
      export HOME=/home/io
      BIN=/home/io/.opencode/bin/opencode
      MARKER=/home/io/.opencode/.pinned-version
      if [ ! -x "$BIN" ] || [ "$(cat "$MARKER" 2>/dev/null)" != "1.18.22" ]; then
        echo "opencode: (re)installing pinned 1.18.22"
        curl -fsSL https://opencode.ai/install | bash -s -- --version 1.18.22
        echo "1.18.22" > "$MARKER"
      fi
      chown -R io:users /home/io/.opencode
      chmod 0555 "$BIN"
    '';
  };
}
