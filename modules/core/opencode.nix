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
#      activation-installed from the Nix store on every switch (the
#      activation-install pattern) — local edits made through the TUI are
#      re-synced away, so the committed config always wins. Contents follow
#      the remediation program in research report
#      opencode-config-improve-1c323b §4:
#      pinned model routing, permission lockdown, task-deny globs for the
#      ultracode subagents, single MCP chokepoint.
#   3. sops secret declarations. zai_api_key/groq_api_key match zed.nix's
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

  # Where matt's interactive clients attach instead of spawning their own
  # background service — see the one-server note in opencode-matt-wrapped. Must
  # match the always-on web server's address; hosts running
  # jupiter.services.opencodeWeb should derive it from that module's `port`.
  mattServerUrl = cfg.mattServerUrl;

  australianEnglish = " Use Australian English spelling in all prose, comments, documentation, and messages (behaviour, colour, organisation, centre, optimise, prioritise, labour, travelled, defence, programme, analogue — not American behavior, color, center, organization, optimize, etc.). Code identifiers, external API names, and verbatim quotations are exempt.";

  australianEnglishInstructions = pkgs.writeText "australian-english.md" ''
    # Language — Australian English

    All English prose produced in this session — including responses, comments, documentation, commit messages, and user-facing text — MUST use Australian English spelling. Examples: behaviour (not behavior), colour (not color), centre (not center), organisation (not organization), optimise (not optimize), prioritise, labour, travelled, defence (not defense), programme, analogue. Do not use American spellings. Code identifiers, external API names, and verbatim quotations are exempt.
  '';

  githubProjectSkill = pkgs.fetchFromGitHub {
    owner = "netresearch";
    repo = "github-project-skill";
    rev = "v2.19.4";
    hash = "sha256-HBEF+tmCkO10H7Di1WI9KiK9kWMf11PjVJx0R+tAUv0=";
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
        # Same endpoint/account as the zed/open-design provider blocks; keys come
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
    # Fail closed — same guard as opencode-matt (8b81796), added here after
    # matt's ssh session hit a 14-line cat-error wall then a keyless launch
    # running io's launcher as matt (2026-09-08). No secret leaked — every
    # read correctly denied — but the wrapper must abort with one clear line
    # instead of exporting empty keys. Guards only the two MANDATORY
    # providers (default + small_model); the optional dsh_env/procurement
    # exports keep their own [ -f ] tolerance.
    for f in ${config.sops.secrets.zai_api_key.path} ${config.sops.secrets.groq_api_key.path}; do
      if ! [ -r "$f" ]; then
        echo "opencode: $f unreadable — this launcher is io's rig (matt's launcher is opencode-matt)" >&2
        exit 1
      fi
    done
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

  # ── matt second environment (jupiter.core.opencode.mattUser) ───────────
  # Motivated 2026-09-06 by the failed XDG-isolation attempt: this opencode
  # build resolves ~/.claude/skills and the legacy ~/.opencode/skills against
  # the REAL home from the passwd entry (observed: HOME override ignored,
  # 53 io skills leaked into the "isolated" env). A real user makes every
  # ~/… scan land in an empty home by construction. Matt is a normal user
  # (no wheel) whose ONLY purpose is trialling the mattpocock/skills
  # registry — 37 skills, NONE of io's. SSH is io's existing authorised key:
  # same human, zero new key material. Secrets: the sops `key` remap gives
  # matt his own 0400 copies of the two provider keys the minimal config
  # references, without widening io's entries or adding ciphertext. Removing
  # the trial is one toggle (mattUser = false) + one user home cleanup.
  # Values (bindings) live here in the let; config block wires them under
  # lib.mkIf cfg.mattUser. Comments live here, not in the JSON.

  # Minimal trial config: the two providers the routing uses, {env:} refs
  # only, autoupdate capped at "notify" so binaries never self-update.
  # Superseded 2026-10-15 by the hand-edited config matt had been living with
  # (lsp / permission / agent / mcp blocks + the parallel plugin): folded in
  # here so the next activation cannot wipe it again.

  # Parallel Web Systems search/extract tools as a native OpenCode 2 plugin.
  # The npm package @parallel-web/opencode-plugin is V1-ONLY: every published
  # version (1.0.0 … 1.3.0-rc.1, last 2026-06-09) default-exports the V1
  # { id, server } shape, which v2 rejects with "Plugin must export a default
  # definition with an id and an effect or setup function" — logged per server
  # start, live on callisto 2026-10-15. This is the same two tools (same names,
  # same descriptions) with the same wire calls the package's `parallel-web` SDK
  # made, verified against Parallel's public OpenAPI 2026-10-15:
  # POST /v1/search (V1SearchRequest: search_queries required, mode enum
  # turbo|fast|basic|advanced) and POST /v1/extract (V1ExtractRequest: urls
  # required), both authenticated with the `x-api-key` header. Written as a
  # dependency-free local plugin (plain ESM, no @opencode/plugin import —
  # the v2 loader only requires a default export carrying `id` + `setup`).
  parallelWebPlugin = pkgs.writeText "parallel-web-plugin.js" ''
    // Parallel Web Systems tools for OpenCode 2 — V2 port of the V1-only npm
    // package @parallel-web/opencode-plugin. Same tools, same names, same API
    // calls; the key comes from PARALLEL_API_KEY, which the opencode-matt
    // launcher exports from sops.
    const API = "https://api.parallel.ai/v1";

    function apiKey() {
      const key = process.env.PARALLEL_API_KEY;
      if (!key) {
        throw new Error(
          "Parallel authentication required: launch through `opencode-matt` " +
            "(it exports PARALLEL_API_KEY from sops) or set PARALLEL_API_KEY.",
        );
      }
      return key;
    }

    async function call(path, body) {
      const res = await fetch(API + path, {
        method: "POST",
        headers: { "content-type": "application/json", "x-api-key": apiKey() },
        body: JSON.stringify(body),
      });
      if (res.status === 401 || res.status === 403) {
        throw new Error("Parallel authentication failed — the API key may be invalid or expired.");
      }
      if (!res.ok) {
        throw new Error("Parallel " + path + " failed: " + res.status + " " + (await res.text()));
      }
      return res.json();
    }

    export default {
      id: "parallel-web",
      async setup(ctx) {
        await ctx.tool.transform((editor) => {
          editor.add({
            name: "parallel-search",
            description: "Search the web using Parallel's Search API. Prefer this over the built-in websearch tool.",
            input: {
              type: "object",
              properties: {
                objective: {
                  type: "string",
                  description:
                    "Natural-language description of what the web search is trying to find. Try to make the search objective atomic, looking for a specific piece of information. May include guidance about preferred sources or freshness.",
                },
                search_queries: {
                  type: "array",
                  items: { type: "string" },
                  description:
                    "Required. 1-5 concise keyword search queries of 3-6 words each (max 200 characters), related to the objective. Prefer 2-3 diverse queries that vary entity names, synonyms, and angles. NEVER write full sentences, instructions, or use site: operators.",
                },
              },
              required: ["search_queries"],
            },
            async execute(input) {
              const result = await call("/search", {
                objective: input.objective,
                search_queries: input.search_queries,
                mode: "advanced",
              });
              return { content: JSON.stringify(result, null, 2) };
            },
          });

          editor.add({
            name: "parallel-fetch",
            description: "Fetch and extract content from one or more URLs using Parallel's Extract API. Prefer this over the built-in webfetch tool.",
            input: {
              type: "object",
              properties: {
                urls: {
                  type: "array",
                  items: { type: "string" },
                  description:
                    "1-20 valid HTTP/HTTPS URLs to extract content from. Batch related URLs into a single call instead of making one call per URL.",
                },
                objective: {
                  type: "string",
                  description:
                    "(optional, recommended) Self-contained, specific natural-language description of what you're looking for across the URLs. Focuses the extracted excerpts on the most relevant content (up to 5000 characters). Omit to return whole-page content.",
                },
                search_queries: {
                  type: "array",
                  items: { type: "string" },
                  description:
                    "(optional) 1-5 concise keyword search queries of 3-6 words each (max 200 characters), used together with the objective to focus extraction. Prefer 2-3 diverse queries. NEVER write full sentences, instructions, or use site: operators.",
                },
              },
              required: ["urls"],
            },
            async execute(input) {
              const result = await call("/extract", {
                urls: input.urls,
                objective: input.objective,
                search_queries: input.search_queries,
              });
              return { content: JSON.stringify(result, null, 2) };
            },
          });
        });
      },
    };
  '';

  mattConfig = pkgs.writeText "opencode-matt.json" (
    builtins.toJSON {
      "$schema" = "https://opencode.ai/config.json";
      model = "zai-coding/glm-5.3";
      small_model = "groq/openai/gpt-oss-20b";
      autoupdate = "notify";
      instructions = [ "${australianEnglishInstructions}" ];

      # ── folded in from matt's hand-edited config 2026-10-15 ──────────────
      # These blocks were edited into /home/matt/.config/opencode/opencode.json
      # outside Nix, so every `nixos-rebuild` activation silently reverted them
      # (the activation script installs this file unconditionally). They are
      # here now so the committed config stays the whole truth.

      # V2 replaces the V1 `plugin` key with `plugins`. The npm entry is gone
      # (V1-only package, see parallelWebPlugin above) and replaced by the
      # activation-installed local port.
      plugins = [ "/home/matt/.config/opencode/plugins/parallel-web" ];

      lsp = true;

      permission = {
        read = "allow";
        edit = "allow";
        glob = "allow";
        grep = "allow";
        list = "allow";
        bash = "allow";
        task = "allow";
        external_directory = "allow";
        todowrite = "allow";
        webfetch = "allow";
        websearch = "allow";
        lsp = "allow";
        skill = "allow";
        question = "allow";
      };

      # Per-agent permission overrides — identical intent across all four
      # (edit/bash/external_directory/webfetch/task allowed), kept verbatim.
      agent = {
        build.permission = {
          edit = "allow";
          bash = "allow";
          external_directory = "allow";
          webfetch = "allow";
          task = "allow";
        };
        plan.permission = {
          edit = "allow";
          bash = "allow";
          external_directory = "allow";
          webfetch = "allow";
          task = "allow";
        };
        general.permission = {
          edit = "allow";
          bash = "allow";
          external_directory = "allow";
          webfetch = "allow";
          task = "allow";
        };
        explore.permission = {
          edit = "allow";
          bash = "allow";
          external_directory = "allow";
          webfetch = "allow";
          task = "allow";
        };
      };

      mcp = {
        wolfram = {
          type = "remote";
          url = "https://agenttools.wolfram.com/mcp";
          enabled = true;
          oauth = false;
        };
        cloudflare = {
          type = "remote";
          url = "https://mcp.cloudflare.com/mcp";
        };
        # Home Assistant lives behind a long-lived access token in the URL
        # path, so the url is a placeholder: the activation script substitutes
        # the real token from the matt-owned sops secret at activation time —
        # never build-time, never in git (see opencodeMattConfig).
        homeassistant = {
          type = "remote";
          enabled = true;
          timeout = 10000;
          url = "http://10.1.1.72:9583/private_@@HA_MCP_TOKEN@@";
        };
        rea = {
          type = "local";
          enabled = true;
          command = [
            "/run/current-system/sw/bin/nix"
            "develop"
            "/home/matt/projects/ukg/toolchain"
            "-c"
            "rea"
            "--mcp"
          ];
          timeout = 300000;
        };
      };

      provider = {
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
        # TokenRouter aggregator (api.tokenrouter.com) — same block as io's
        # builtinConfig (model ids verified against its live /v1/models
        # 2026-08-29; kimi-k3 output cap unpublished so no limit block).
        # Requested for matt 2026-09-08; default routing stays zai-coding.
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
    }
  );

  # opencode-matt launcher: same secrets-by-path pattern as opencode-wrapped,
  # but reading the MATT-owned remapped secret files. Fails CLOSED: the
  # [ -r ] guards abort with a clear error if the runner can't read matt's
  # secrets (e.g. io ran it by mistake) instead of launching with empty
  # keys against the wrong config.
  opencode-matt-wrapped = pkgs.writeShellScriptBin "opencode-matt" ''
    for f in ${config.sops.secrets.zai_api_key_matt.path} ${config.sops.secrets.groq_api_key_matt.path} ${config.sops.secrets.tokenrouter_api_key_matt.path}; do
      if ! [ -r "$f" ]; then
        echo "opencode-matt: $f unreadable — this launcher is for matt (is HOME=/home/matt?)" >&2
        exit 1
      fi
    done
    export Z_AI_API_KEY="$(cat ${config.sops.secrets.zai_api_key_matt.path})"
    export GROQ_API_KEY="$(cat ${config.sops.secrets.groq_api_key_matt.path})"
    export TOKENROUTER_API_KEY="$(cat ${config.sops.secrets.tokenrouter_api_key_matt.path})"
    # Parallel Web Systems — read by the local V2 plugin (parallelWebPlugin)
    # to register parallel-search / parallel-fetch. Under V1 this key lived in
    # opencode's own auth store, picked up by the npm plugin's auth loader; v2
    # plugins read keys from the environment, so it moves to sops like the
    # others. Optional: a missing secret leaves the tools reporting
    # "Parallel authentication required" rather than failing the launcher.
    if [ -r ${config.sops.secrets.parallel_api_key_matt.path} ]; then
      export PARALLEL_API_KEY="$(cat ${config.sops.secrets.parallel_api_key_matt.path})"
    fi
    # ── one server per account ────────────────────────────────────────────
    # opencode 2.0 clients auto-start (then discover) a SHARED background
    # service, while `serve` is the standalone foreground server. Both end up
    # on the same ~/.local/share/opencode/opencode.db, and two servers mean two
    # writers: observed live on callisto 2026-10-15, the interactive service
    # held the SQLite write lock and the systemd web server's V1-migration
    # INSERT died with "SQLiteError: database is locked" (its session writes
    # failed the same way, twice). So CLIENT invocations attach to the
    # always-on systemd server instead of spawning a private one; server /
    # lifecycle subcommands pass straight through. The client needs the same
    # basic-auth credentials the server was started with.
    if [ -r ${config.sops.secrets.opencode_server_password_matt.path} ]; then
      export OPENCODE_SERVER_USERNAME="opencode"
      export OPENCODE_SERVER_PASSWORD="$(cat ${config.sops.secrets.opencode_server_password_matt.path})"
    fi
    # EmDash CLI (jupiter.au CMS) — used by the build-in-public skill from
    # matt's sessions: personal API token + Cloudflare Access service-token
    # headers. All-or-nothing and optional: absent secrets leave these unset
    # and the CLI reports "Not logged in" instead. The components are exported
    # separately because CLI 1.0.1's `whoami` drops custom headers entirely
    # (env and -H alike); the skill passes them as explicit -H flags on every
    # command, which is the proven-working form.
    if [ -r ${config.sops.secrets.emdash_token.path} ] \
      && [ -r ${config.sops.secrets.cf_access_client_id.path} ] \
      && [ -r ${config.sops.secrets.cf_access_client_secret.path} ]; then
      export EMDASH_TOKEN="$(cat ${config.sops.secrets.emdash_token.path})"
      export CF_ACCESS_CLIENT_ID="$(cat ${config.sops.secrets.cf_access_client_id.path})"
      export CF_ACCESS_CLIENT_SECRET="$(cat ${config.sops.secrets.cf_access_client_secret.path})"
      export EMDASH_HEADERS="$(printf 'CF-Access-Client-Id: %s\nCF-Access-Client-Secret: %s' \
        "$CF_ACCESS_CLIENT_ID" "$CF_ACCESS_CLIENT_SECRET")"
    fi
    case "''${1:-}" in
      serve | service | auth | upgrade | update | uninstall | plugin | models | stats | debug | mcp | --help | -h | --version | -v | --completions)
        exec "$HOME/.opencode/bin/opencode" "$@"
        ;;
      *)
        exec "$HOME/.opencode/bin/opencode" --server "${mattServerUrl}" "$@"
        ;;
    esac
  '';
in
{
  options.jupiter.core.opencode = {
    enable = lib.mkEnableOption ''
      opencode agent rig: sops-keyed wrapped launcher + activation-installed
      canonical config. Requires the per-user binary at ~/.opencode/bin/opencode
      (official installer, pinned to 1.18.22 and locked non-writable).
    '';

    # Second opencode user ("matt") for trialling the mattpocock/skills
    # registry in a fully separate account — motivated 2026-09-06 by the
    # XDG-isolation attempt, which measurably leaked 53 main-env skills into
    # the trial env: this opencode build resolves ~/.claude/skills and the
    # legacy ~/.opencode/skills against the REAL home from the passwd entry
    # (observed: HOME override ignored, 50 .claude + 3 .opencode skills
    # visible in the "isolated" env). A real user makes every ~/… scan land
    # in an empty home by construction — no escape-hatch flags, and the
    # isolation holds across future opencode self-updates. The wrapper,
    # config, and skills live in this module so the account is a one-line
    # removal (jupiter.core.opencode.mattUser = false) if the trial is
    # abandoned.
    mattUser = lib.mkEnableOption ''
      the "matt" second opencode environment: a normal (non-wheel) user with
      its own opencode-matt launcher (matt-owned sops remaps of the existing
      zai/groq keys), a minimal 2-provider config, and mattpocock/skills
      registry skills ONLY — none of io's skills, agents, commands, plugins,
      MCP servers, or session history. SSH via io's existing authorised key.
    '';

    mattServerUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:4096";
      description = ''
        Address matt's interactive opencode clients attach to (`--server`) so
        they do not spawn a second server against the same SQLite store. Must
        match the always-on web server — hosts running
        jupiter.services.opencodeWeb should derive it from that module's
        `port`. Server/lifecycle subcommands are never rewritten.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # io's wrapper always; matt's launcher only when his environment is on.
    environment.systemPackages = [
      opencode-wrapped
    ]
    ++ lib.optionals cfg.mattUser [ opencode-matt-wrapped ];

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
    sops.secrets.procurement_tmapi_token = {
      sopsFile = ../../secrets/procurement.yaml;
      owner = "io";
      mode = "0400";
    };
    sops.secrets.procurement_sociavault_key = {
      sopsFile = ../../secrets/procurement.yaml;
      owner = "io";
      mode = "0400";
    };
    sops.secrets.procurement_apify_token = {
      sopsFile = ../../secrets/procurement.yaml;
      owner = "io";
      mode = "0400";
    };
    sops.secrets.procurement_database_url = {
      sopsFile = ../../secrets/procurement.yaml;
      owner = "io";
      mode = "0400";
    };
    sops.secrets.procurement_ebay_app_id = {
      sopsFile = ../../secrets/procurement.yaml;
      owner = "io";
      mode = "0400";
    };
    sops.secrets.procurement_ebay_cert_id = {
      sopsFile = ../../secrets/procurement.yaml;
      owner = "io";
      mode = "0400";
    };
    sops.secrets.procurement_ebay_deletion_token = {
      sopsFile = ../../secrets/procurement.yaml;
      owner = "io";
      mode = "0400";
    };

    # ~/.config is already persisted for io where impermanence applies;
    # callisto runs plain ext4. Re-synced on every activation, so the
    # committed config always wins over edits made through the TUI.
    system.activationScripts.opencodeConfig = lib.stringAfter [ "users" ] ''
      install -D -m 0644 -o io -g users ${builtinConfig} /home/io/.config/opencode/opencode.json
    '';

    # ── matt second environment ────────────────────────────────────────────
    # All of this exists only when jupiter.core.opencode.mattUser is true.

    users.users.matt = lib.mkIf cfg.mattUser {
      isNormalUser = true;
      # Own primary group — NOT the shared "users" group (see the group
      # comment below). Verified necessary: declaring users.groups.matt
      # alone left the primary group at the isNormalUser default ("users",
      # gid 100) and the dsh_env leak survived a deploy before this line.
      group = "matt";
      # Same human, existing key material — zero new credentials.
      openssh.authorizedKeys.keys = config.users.users.io.openssh.authorizedKeys.keys;
    };

    # matt gets his own primary group ("matt") so he is NOT in the shared
    # "users" group. Verified necessary 2026-09-08: the fleet's dsh_env
    # secret is root:users 0440 (pre-existing decision so io can read it),
    # and a plain isNormalUser lands in "users" as primary group — which
    # let matt read the packed OPENCODE/PARALLEL/MODEL_ROUTER tokens and
    # defeated this environment's credential isolation.
    users.groups.matt = lib.mkIf cfg.mattUser { };

    # Matt-readable copies of the two provider keys the minimal config
    # references — the sops-nix `key` remap (README §"Share secrets between
    # different users") points at the same YAML keys io's entries read, so
    # no new ciphertext, io's 0400 entries untouched, nothing group-readable.
    sops.secrets.zai_api_key_matt = lib.mkIf cfg.mattUser {
      key = "zai_api_key";
      owner = "matt";
      mode = "0400";
    };
    sops.secrets.groq_api_key_matt = lib.mkIf cfg.mattUser {
      key = "groq_api_key";
      owner = "matt";
      mode = "0400";
    };
    sops.secrets.tokenrouter_api_key_matt = lib.mkIf cfg.mattUser {
      key = "tokenrouter_api_key";
      owner = "matt";
      mode = "0400";
    };

    # EmDash CMS (jupiter.au) credentials for matt's rig — consumed by the
    # build-in-public skill's `npx emdash` calls, exported by the launcher
    # above. New YAML keys (no io counterpart), written by the capture
    # wizard; missing values are tolerated.
    sops.secrets.emdash_token = lib.mkIf cfg.mattUser {
      owner = "matt";
      mode = "0400";
    };
    sops.secrets.cf_access_client_id = lib.mkIf cfg.mattUser {
      owner = "matt";
      mode = "0400";
    };
    sops.secrets.cf_access_client_secret = lib.mkIf cfg.mattUser {
      owner = "matt";
      mode = "0400";
    };

    # opencode 2.0 made the server password-protected unconditionally ("The
    # web ui ... is available by default and password protected") where v1
    # served unsecured and leaned on Cloudflare Access alone. Without a stable
    # value the standalone server mints a random one per start and prints it to
    # the journal, which signs the browser out on every restart — so it comes
    # from sops like everything else, and the launcher exports it for clients
    # attaching with --server.
    sops.secrets.opencode_server_password_matt = lib.mkIf cfg.mattUser {
      owner = "matt";
      mode = "0400";
    };

    # Parallel Web Systems API key for the local V2 parallel-search /
    # parallel-fetch plugin. Under V1 the npm plugin read it out of opencode's
    # own auth store via its auth loader; v2 plugins take keys from the
    # environment, so it lives here (captured from that store 2026-10-15).
    sops.secrets.parallel_api_key_matt = lib.mkIf cfg.mattUser {
      owner = "matt";
      mode = "0400";
    };

    # Home Assistant long-lived access token for matt's remote MCP entry. It
    # lives in the MCP URL path, so it is substituted into the installed
    # config at activation (see opencodeMattConfig) rather than written into
    # the store path or committed.
    sops.secrets.ha_mcp_token_matt = lib.mkIf cfg.mattUser {
      owner = "matt";
      mode = "0400";
    };

    # Activation-install the canonical matt config (same doctrine as io's:
    # the committed config always wins over TUI edits). Skills are NOT
    # activation-managed — no pinned upstream exists for the skills.sh
    # opencode-filtered subset; they're a one-time copy at provision time,
    # then `skills update` as matt owns them.
    #
    # The config carries an @@HA_MCP_TOKEN@@ placeholder in the Home Assistant
    # MCP url (the token is a long-lived access token in the url path), so the
    # secret is substituted HERE — activation-time, never build-time, never in
    # git. A missing secret leaves the placeholder visible and the entry
    # broken rather than silently writing a literal.
    #
    # The local V2 parallel-web plugin is installed alongside it: opencode
    # resolves the absolute path listed in `plugins`, and the package.json
    # marks the directory as ESM with no dependencies to install.
    system.activationScripts.opencodeMattConfig = lib.mkIf cfg.mattUser (
      lib.stringAfter [ "users" ] ''
        cfg=/home/matt/.config/opencode/opencode.json
        install -D -m 0644 -o matt -g users ${mattConfig} "$cfg"
        if [ -r ${config.sops.secrets.ha_mcp_token_matt.path} ]; then
          ${pkgs.gnused}/bin/sed -i \
            "s|@@HA_MCP_TOKEN@@|$(tr -d '\n' < ${config.sops.secrets.ha_mcp_token_matt.path})|" "$cfg"
        fi
        plugin_dir=/home/matt/.config/opencode/plugins/parallel-web
        mkdir -p "$plugin_dir"
        install -m 0644 -o matt -g users ${parallelWebPlugin} "$plugin_dir/index.js"
        cat > "$plugin_dir/package.json" <<'EOF'
        {
          "name": "parallel-web-plugin",
          "version": "2.0.0",
          "type": "module",
          "main": "./index.js"
        }
        EOF
        chown matt:users "$plugin_dir/package.json"
        chmod 0644 "$plugin_dir/package.json"
      ''
    );

    # Global skill: github-project (Netresearch) — repository setup, branch
    # protection, issue hierarchies, auto-merge. Installed to both the
    # universal ~/.agents/skills and the OpenCode-specific path so every
    # session (regardless of discovery order) sees it. Pinned to v2.19.4.
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
