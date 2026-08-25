{
  config,
  lib,
  pkgs,
  ...
}:

# opencode (V1 1.18.x) agent rig — the remote coding-agent harness on the
# serving host, migrated off io's laptop (2026-08-24 planning session,
# docs/plans/2026-08-24-001-callisto-opencode-rig-deployment.md).
#
# Three pieces:
#   1. `opencode-wrapped` launcher: exports provider keys from sops secrets
#      into the environment, then execs the PER-USER binary at
#      ~/.opencode/bin/opencode (installed by the official installer as io,
#      pinned to 1.18.x — deliberately NOT a nixpkgs package: opencode's
#      auto-updater and plugin host assume that layout, and V2 must stay
#      out until plugin-API parity, so version control stays with io).
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
# Model ids verified against live catalogs 2026-08-25: `opencode models`
# on 1.18.22 + the opencode zen gateway's /models + dsh settingsFile
# spelling all agree on glm-5.3, llama-3.1-8b-instant, kimi-k2.7-code,
# minimax-m3. Limit numbers follow dsh settingsFile / live models.dev —
# llama-3.1-8b-instant output is 131072 per BOTH (the plan draft's 32768
# was stale), minimax-m3 keeps dsh's field-proven 1000000/131072 even
# though models.dev currently lists 512000/128000 (dsh has run that cap
# as its per-request default against this same gateway since 2026-08-20).
let
  cfg = config.jupiter.core.opencode;

  # THE canonical config (see module header). Comments live here, not in
  # the JSON. The watcher key was schema-probed against 1.18.22
  # (`opencode debug config` drops unknown keys but resolves this one).
  builtinConfig = pkgs.writeText "opencode.json" (
    builtins.toJSON {
      "$schema" = "https://opencode.ai/config.json";
      # Pinned routing: big model for work, groq instant for title-gen
      # (closes the main-model title-gen leak on this box).
      model = "zai-coding/glm-5.3";
      small_model = "groq/llama-3.1-8b-instant";
      # V1 construct; required by open-ultracode. Inert on V2 (Phase 2).
      subagent_depth = 2;
      watcher = {
        ignore = [
          "**/node_modules/**"
          "**/.git/**"
          "**/research/raw/**"
        ];
      };
      permission = {
        "*" = "allow";
        read = {
          "*" = "allow";
          "*.env" = "deny";
          "*.env.*" = "deny";
          "*.env.example" = "allow";
        };
        bash = {
          "*" = "allow";
          "git push" = "ask";
          "git push *" = "ask";
          "curl * -X POST *" = "ask";
          "curl * -X PUT *" = "ask";
          "curl * -X PATCH *" = "ask";
          "curl * -X DELETE *" = "ask";
          "curl * -d *" = "ask";
          "curl * --data*" = "ask";
          "curl * -F *" = "ask";
          "curl * --form *" = "ask";
          "curl * -T *" = "ask";
          "curl * --request POST *" = "ask";
          "curl * --request PUT *" = "ask";
          "curl * --request PATCH *" = "ask";
          "curl * --request DELETE *" = "ask";
          "ssh *" = "ask";
          "scp *" = "ask";
          "sftp *" = "ask";
          "rsync *" = "ask";
          "rm -rf /*" = "deny";
          "rm -rf ~*" = "deny";
          "sudo rm *" = "deny";
          "nixos-rebuild *" = "ask";
        };
        task = {
          "*" = "allow";
          "open-ultracode-*" = "deny";
          "ultracode-fusion-*" = "deny";
        };
        external_directory = "ask";
        webfetch = "allow";
        doom_loop = "ask";
        cloudflare_execute = "ask";
      };
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
            "llama-3.1-8b-instant" = {
              limit = {
                context = 131072;
                output = 131072;
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
  opencode-wrapped = pkgs.writeShellScriptBin "opencode" ''
    export Z_AI_API_KEY="$(cat ${config.sops.secrets.zai_api_key.path})"
    export GROQ_API_KEY="$(cat ${config.sops.secrets.groq_api_key.path})"
    export OPENCODE_API_KEY="$(sed -n 's/^OPENCODE_API_KEY=//p' ${config.sops.secrets.dsh_env.path})"
    exec "$HOME/.opencode/bin/opencode" "$@"
  '';
in
{
  options.jupiter.core.opencode = {
    enable = lib.mkEnableOption ''
      opencode agent rig: sops-keyed wrapped launcher + activation-installed
      canonical config. Requires the per-user binary at ~/.opencode/bin/opencode
      (official installer, pinned to V1 1.18.x).
    '';
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ opencode-wrapped ];

    sops.secrets.zai_api_key = {
      owner = "io";
      mode = "0400";
    };

    sops.secrets.groq_api_key = {
      owner = "io";
      mode = "0400";
    };

    # ~/.config is already persisted for io where impermanence applies;
    # callisto runs plain ext4. Re-synced on every activation, so the
    # committed config always wins over edits made through the TUI.
    system.activationScripts.opencodeConfig = lib.stringAfter [ "users" ] ''
      install -D -m 0644 -o io -g users ${builtinConfig} /home/io/.config/opencode/opencode.json
    '';
  };
}
