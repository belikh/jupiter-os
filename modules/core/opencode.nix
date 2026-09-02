{
  config,
  lib,
  pkgs,
  ...
}:

# opencode (tracks latest upstream) agent rig — the remote coding-agent
# harness on the serving host, migrated off io's laptop (2026-08-24 planning
# session, docs/plans/2026-08-24-001-callisto-opencode-rig-deployment.md).
#
# Three pieces:
#   1. `opencode-wrapped` launcher: exports provider keys from sops secrets
#      into the environment, then execs the PER-USER binary at
#      ~/.opencode/bin/opencode (installed by the official installer as io).
#      That binary SELF-UPDATES to the latest opencode release; we let it
#      track latest rather than pinning. (An earlier attempt to pin 1.18.22
#      was based on a mistaken belief that the 1.18.22→1.18.23 bump was a V2
#      break — it was just a patch bump, and the Discord bridge's failures
#      were the 2000-char stream-edit bug + the model's idle-wait on a
#      clarifying question, not the version.) Deliberately NOT a nixpkgs
#      package: opencode's plugin host and the per-user layout assume
#      ~/.opencode/bin.
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
# empero-free + tokenrouter added 2026-08-29; tokenrouter ids verified
# against its live /v1/models (glm-5.3-free answered a probe chat).
let
  cfg = config.jupiter.core.opencode;

  australianEnglish = " Use Australian English spelling in all prose, comments, documentation, and messages (behaviour, colour, organisation, centre, optimise, prioritise, labour, travelled, defence, programme, analogue — not American behavior, color, center, organization, optimize, etc.). Code identifiers, external API names, and verbatim quotations are exempt.";

  australianEnglishInstructions = pkgs.writeText "australian-english.md" ''
    # Language — Australian English

    All English prose produced in this session — including responses, comments, documentation, commit messages, and user-facing text — MUST use Australian English spelling. Examples: behaviour (not behavior), colour (not color), centre (not center), organisation (not organization), optimise (not optimize), prioritise, labour, travelled, defence (not defense), programme, analogue. Do not use American spellings. Code identifiers, external API names, and verbatim quotations are exempt.
  '';

  githubProjectSkill = pkgs.fetchFromGitHub {
    owner = "netresearch";
    repo = "github-project-skill";
    rev = "v2.17.0";
    hash = "sha256-tUx89rf5hxoTp25MBdmMLUvB59vAbingERbKtRCeJB4=";
  };

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
      # headless via the web UI, where any ask/deny prompt deadlocks
      # the session forever (observed live: external_directory=ask hung a
      # build-agent thread on ~/.config/opencode). io accepts the tradeoff
      # on a serving host; git pushes are still reviewed post-hoc by io.
      permission = "allow";
      instructions = [ "${australianEnglishInstructions}" ];
      # Explicit primary agents so the web UI's "Show agent Picker" actually
      # shows both Build and Plan. Without this, the new layout (v1.18.1+)
      # hides the toggle and only Plan appears. Build was being overridden
      # by the ultracode plugin's subagent definition (mode=subagent), so we
      # force it back to primary with an explicit prompt and hidden=false,
      # and also add a dedicated "code" primary as a fallback that the
      # plugin does not define.
      agent = {
        build = {
          mode = "all";
          hidden = false;
          description = "Build — full tool access for implementation";
          prompt =
            "You are the build agent. You have full tool access to read, edit, and execute commands. Implement the requested changes directly."
            + australianEnglish;
          permission = {
            edit = "allow";
            bash = "allow";
          };
        };
        plan = {
          mode = "primary";
          hidden = false;
          description = "Plan — read-only analysis and sequencing";
          prompt =
            "You are the plan agent. You are read-only: analyze the codebase, sequence the work, and describe what you would do without making any file edits or running any bash commands. Put the plan in .opencode/plans/*.md if needed."
            + australianEnglish;
          permission = {
            edit = "ask";
            bash = "ask";
          };
        };
        code = {
          mode = "primary";
          hidden = false;
          description = "Code — full implementation (Build fallback)";
          prompt =
            "You are the code agent. You have full tool access to read, edit, and execute commands. Implement the requested changes directly."
            + australianEnglish;
          permission = {
            edit = "allow";
            bash = "allow";
          };
        };
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
        # Free community endpoint (key is the literal "free" — public, not a
        # secret, so no sops entry). Catalogue swapped to GLM mid-migration
        # 2026-08-29 ("switching the free endpoint to new models"); limits
        # from Z.AI's published glm-5.3-flash spec (1M context / 128K out).
        "empero-free" = {
          npm = "@ai-sdk/openai-compatible";
          name = "Empero Free";
          options = {
            baseURL = "https://free.empero.org/v1";
            apiKey = "free";
          };
          models = {
            "glm-5.3-flash" = {
              limit = {
                context = 1000000;
                output = 131072;
              };
            };
          };
        };
        # TokenRouter (api.tokenrouter.com) aggregator. Model ids verified
        # against the live /v1/models catalogue 2026-08-29 (131 models;
        # glm-5.3-free confirmed present and answering — it routes to
        # upstream glm-5.3 with thinking forced on). Limits from vendor
        # docs: Z.AI (glm-5.3/-flash 1M/128K), Qwen blog + OpenRouter
        # (qwen3.8-max 1M/128K), Google Cloud (gemini-3.7-flash 1M/64K).
        # kimi-k3 output cap is unpublished — deliberately unset, not
        # guessed. The endpoint's /models carries no limit metadata.
        tokenrouter = {
          npm = "@ai-sdk/openai-compatible";
          name = "TokenRouter";
          options = {
            baseURL = "https://api.tokenrouter.com/v1";
            apiKey = "{env:TOKENROUTER_API_KEY}";
          };
          models = {
            "z-ai/glm-5.3-free" = {
              limit = {
                context = 1000000;
                output = 131072;
              };
            };
            "z-ai/glm-5.3-flash" = {
              limit = {
                context = 1000000;
                output = 131072;
              };
            };
            # kimi-k3 output cap is unverifiable (vendor docs don't publish
            # it; the account has $0 credit so the API won't even validate
            # max_tokens) — and the config schema requires limit.context AND
            # limit.output or neither, so no limit block at all.
            "moonshotai/kimi-k3" = { };
            "qwen/qwen3.8-max" = {
              limit = {
                context = 1000000;
                output = 131072;
              };
            };
            "google/gemini-3.7-flash" = {
              limit = {
                context = 1048576;
                output = 65536;
              };
            };
          };
        };
      };
      # Model Router (router.jupiter.au) — this fleet's own gateway
      # (github.com/belikh/model-router, running on callisto behind its
      # Cloudflare tunnel; jupiter.services.modelRouter). Pools every free
      # LLM inference tier behind one OpenAI-compatible endpoint: the
      # model ids are the router's pool FAMILIES (glm-4x-flash, glm-5.2,
      # qwen3.8, kimi-k3, deepseek-v4-flash, glm-5.3-flash via
      # ollama-cloud capped / stealth windows), each backed by however
      # many free endpoints currently serve it. Key is the router's own
      # client token (MODEL_ROUTER_TOKEN, shared with dsh/OpenDesign via
      # the wrapper env; the router holds the provider keys in its vault).
      # Added 2026-09-01 alongside the callisto service.
      "model-router" = {
        npm = "@ai-sdk/openai-compatible";
        name = "Model Router (jupiter)";
        options = {
          baseURL = "https://router.jupiter.au/v1";
          apiKey = "{env:MODEL_ROUTER_TOKEN}";
        };
        models = {
          # limits are the pool's WORST-case member per family (seed matrix):
          # glm-4x-flash: openrouter :free 256K/zai glm-4.7-flash 128K → 128K/32K
          "glm-4x-flash" = {
            limit = {
              context = 131072;
              output = 32768;
            };
          };
          # glm-5.2: openrouter z-ai/glm-5.2:free 256K → 262144/32768
          "glm-5.2" = {
            limit = {
              context = 262144;
              output = 32768;
            };
          };
          # qwen3.8: groq qwen3.8-27b 131072 (2M TPD free allowance)
          "qwen3.8" = {
            limit = {
              context = 131072;
              output = 32768;
            };
          };
          # kimi-k3: NVIDIA NIM 1M/128K (free-tier anchor)
          "kimi-k3" = {
            limit = {
              context = 1000000;
              output = 131072;
            };
          };
          # deepseek-v4-flash: NIM 1M class
          "deepseek-v4-flash" = {
            limit = {
              context = 1000000;
              output = 131072;
            };
          };
          # glm-5.3-flash: ollama cloud capped tier (literal free hosting)
          "glm-5.3-flash" = {
            limit = {
              context = 1000000;
              output = 131072;
            };
          };
        };
      };
      mcp.cloudflare = {
        type = "remote";
        url = "https://mcp.cloudflare.com/mcp";
      };
      # Home Assistant MCP server (mcp-ha-connect add-on) — LAN-direct to the
      # HA box (fleet.nix address; callisto has no mDNS). Auth is the
      # /private_<token> URL path; {env:} interpolation keeps the token out
      # of the committed config. Endpoint is POST-only streamable HTTP
      # (verified live 2026-08-29: initialize → 200, bare GET → 405).
      mcp.homeassistant = {
        type = "remote";
        url = "http://${config.jupiter.fleet.addresses.homeassistant}:9583/private_{env:HA_MCP_TOKEN}";
        enabled = true;
        timeout = 10000;
      };
      # Procurement MCP — federated Chinese + AU procurement search (TMAPI / eBay AU / SociaVault / Apify).
      # Integration-only — no scrapers built here; every source is a hosted API.
      # Remote (streamable-HTTP) against the systemd unit (modules/services/
      # procurement-mcp.nix) on 127.0.0.1:8787 — one long-lived process instead
      # of a stdio spawn per opencode session. Killed-session drift (stale
      # server.py code in memory) was the failure mode that motivated this.
      # Keys are loaded by the unit's sops EnvironmentFile, so the wrapper's
      # env exports are no longer needed for this server (they remain for any
      # manual CLI use of server.py).
      mcp.procurement = {
        type = "remote";
        url = "http://127.0.0.1:8787/mcp";
        enabled = true;
        timeout = 30000;
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
  # dsh_env packs KEY=value lines; sed pulls just the ones we need.
  # PARALLEL_API_KEY authenticates the parallel-search/fetch MCP tools and
  # hyperresearch's parallel lane (observed missing 2026-08-29: every
  # Parallel call died before reaching the network).
  opencode-wrapped = pkgs.writeShellScriptBin "opencode" ''
    export Z_AI_API_KEY="$(cat ${config.sops.secrets.zai_api_key.path})"
    export GROQ_API_KEY="$(cat ${config.sops.secrets.groq_api_key.path})"
    export OPENCODE_API_KEY="$(sed -n 's/^OPENCODE_API_KEY=//p' ${config.sops.secrets.dsh_env.path})"
    export PARALLEL_API_KEY="$(sed -n 's/^PARALLEL_API_KEY=//p' ${config.sops.secrets.dsh_env.path})"
    export TOKENROUTER_API_KEY="$(cat ${config.sops.secrets.tokenrouter_api_key.path})"
    # Model Router client token (router.jupiter.au) — the fleet's own
    # gateway on callisto. The router pre-seeds this same token on first
    # boot from MODEL_ROUTER_TOKEN in its env (jupiter.services.modelRouter
    # envFile), so consumers share one credential.
    if [ -n "''${MODEL_ROUTER_SOPS_PATH:-}" ]; then export MODEL_ROUTER_TOKEN="$(cat "$MODEL_ROUTER_SOPS_PATH")"; fi
    if grep -q '^MODEL_ROUTER_TOKEN=' ${config.sops.secrets.dsh_env.path} 2>/dev/null; then export MODEL_ROUTER_TOKEN="$(sed -n 's/^MODEL_ROUTER_TOKEN=//p' ${config.sops.secrets.dsh_env.path})"; fi
    export CLOUDFLARE_BROWSER_RUN_TOKEN="$(cat ${config.sops.secrets.cloudflare_browser_run_token.path})"
    export CF_ACCOUNT_ID="19f62c2ef7861336d274166233ba3a17"
    export HA_MCP_TOKEN="$(cat ${config.sops.secrets.ha_mcp_token.path})"
    # Procurement MCP — Chinese + AU federated search (callisto, 10.1.1.3 Postgres cache)
    if [ -f ${config.sops.secrets.procurement_tmapi_token.path} ]; then export TMAPI_TOKEN="$(cat ${config.sops.secrets.procurement_tmapi_token.path})"; fi
    if [ -f ${config.sops.secrets.procurement_sociavault_key.path} ]; then export SOCIAVAULT_API_KEY="$(cat ${config.sops.secrets.procurement_sociavault_key.path})"; fi
    if [ -f ${config.sops.secrets.procurement_apify_token.path} ]; then export APIFY_TOKEN="$(cat ${config.sops.secrets.procurement_apify_token.path})"; fi
    if [ -f ${config.sops.secrets.procurement_database_url.path} ]; then export DATABASE_URL="$(cat ${config.sops.secrets.procurement_database_url.path})"; fi
    if [ -f ${config.sops.secrets.procurement_ebay_app_id.path} ]; then export EBAY_APP_ID="$(cat ${config.sops.secrets.procurement_ebay_app_id.path})"; fi
    if [ -f ${config.sops.secrets.procurement_ebay_cert_id.path} ]; then export EBAY_CERT_ID="$(cat ${config.sops.secrets.procurement_ebay_cert_id.path})"; fi
    if [ -f ${config.sops.secrets.procurement_ebay_deletion_token.path} ]; then export EBAY_DELETION_TOKEN="$(cat ${config.sops.secrets.procurement_ebay_deletion_token.path})"; fi
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

    # TokenRouter aggregator key (api.tokenrouter.com) — provider block
    # lives in builtinConfig under `tokenrouter`, {env:TOKENROUTER_API_KEY}.
    sops.secrets.tokenrouter_api_key = {
      owner = "io";
      mode = "0400";
    };

    # Home Assistant MCP path token (mcp-ha-connect). Recovered blind from
    # fish history into sops (never displayed) 2026-08-29.
    sops.secrets.ha_mcp_token = {
      owner = "io";
      mode = "0400";
    };

    # Procurement MCP — federated Chinese + AU procurement (integration-only, no scrapers).
    # Hosted on callisto; opencode spawns it per session as local stdio (mcp.procurement above).
    # Fleet Postgres on 10.1.1.3 `jupiter` db per stack law when DATABASE_URL is set.
    sops.secrets.procurement_tmapi_token = { sopsFile = ../../secrets/procurement.yaml; owner = "io"; mode = "0400"; };
    sops.secrets.procurement_sociavault_key = { sopsFile = ../../secrets/procurement.yaml; owner = "io"; mode = "0400"; };
    sops.secrets.procurement_apify_token = { sopsFile = ../../secrets/procurement.yaml; owner = "io"; mode = "0400"; };
    sops.secrets.procurement_database_url = { sopsFile = ../../secrets/procurement.yaml; owner = "io"; mode = "0400"; };
    sops.secrets.procurement_ebay_app_id = { sopsFile = ../../secrets/procurement.yaml; owner = "io"; mode = "0400"; };
    sops.secrets.procurement_ebay_cert_id = { sopsFile = ../../secrets/procurement.yaml; owner = "io"; mode = "0400"; };
    sops.secrets.procurement_ebay_deletion_token = { sopsFile = ../../secrets/procurement.yaml; owner = "io"; mode = "0400"; };

    # ~/.config is already persisted for io where impermanence applies;
    # callisto runs plain ext4. Re-synced on every activation, so the
    # committed config always wins over edits made through the TUI.
    system.activationScripts.opencodeConfig = lib.stringAfter [ "users" ] ''
      install -D -m 0644 -o io -g users ${builtinConfig} /home/io/.config/opencode/opencode.json
    '';

    # Global skill: github-project (Netresearch) — repository setup, branch
    # protection, issue hierarchies, auto-merge. Installed to both the
    # universal ~/.agents/skills and the OpenCode-specific path so every
    # session (regardless of discovery order) sees it. Pinned to v2.17.0.
    system.activationScripts.githubProjectSkill = lib.stringAfter [ "users" ] ''
      for dest in /home/io/.agents/skills/github-project /home/io/.config/opencode/skills/github-project; do
        mkdir -p "$(dirname "$dest")"
        rm -rf "$dest"
        cp -r ${githubProjectSkill}/skills/github-project "$dest"
        # NixOS has no /bin/bash (only /run/current-system/sw/bin/bash and
        # /usr/bin/env). Upstream verify script uses #!/bin/bash — patch it.
        ${pkgs.gnused}/bin/sed -i 's|#!/bin/bash|#!/usr/bin/env bash|' "$dest/scripts/verify-github-project.sh" || true
        chown -R io:users "$dest"
        chmod -R u+rw,go+r "$dest"
        chmod +x "$dest/scripts/"*.sh 2>/dev/null || true
      done
    '';

  };
}
