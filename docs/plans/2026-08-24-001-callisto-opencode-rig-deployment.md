# Deployment Plan — opencode + hyperresearch rig on callisto

**Status:** READY TO EXECUTE · **Created:** 2026-08-24 · **Origin:** self-improvement research run `opencode-config-improve-1c323b`
**Executor instructions:** work WPs strictly in order; every gate is observed, never asserted. Commit per jupiter-os house rules (`CLAUDE.md`): eval → commit+push → on-host `nixos-rebuild switch` as root → verify by observation. Never decrypt/print secret values. Never edit the laptop vault after WP4's rsync (it becomes a frozen archive).

---

## 0. Objective & locked decisions

Stand up opencode v1.18.x + hyperresearch on **callisto**, applying the remediation program from `research/notes/final_report_opencode-config-improve-1c323b.md`, vault migrated from laptop, Discord deferred.

| Decision | Value |
|---|---|
| Host | callisto (10.1.1.3, NixOS 26.11, diskless iSCSI root off europa zvol `tank/services/callisto-root`) |
| User | `io` (no dedicated agent user) |
| Config | ONE canonical file, Nix activation-installed (never drifts) |
| Vault | Migrate ALL of laptop `/home/io/research` + `~/.hyperresearch/{hyperresearch.db,config.toml,templates/}` → callisto authoritative; laptop = frozen archive |
| Gear | `full` |
| `subagent_depth` | `2` (open-ultracode requires it; V1 construct) |
| opencode version | **V1 1.18.x — NOT V2** ("V1 plugins will not work in V2" per official migrate guide; lockdown+ultracode plugins proven only on 1.18.21; `subagent_depth` inert on V2). Side-by-side `opencode2` evaluation = Phase 2 |
| Discord bridge | DEFERRED to Phase 2 (remote-opencode chosen; Node 24 already committed for it: `f0318cc`) |
| Browser lane | Feature-requested upstream ([issue #2](https://github.com/belikh/hyperresearch-opencode/issues/2)); deployment only provisions sops token + env vars (WP7-lite) |
| Postgres backend | Feature-requested upstream ([issue #1](https://github.com/belikh/hyperresearch-opencode/issues/1)); SQLite ships now |

## 1. Verified ground truth (do not re-derive)

- callisto live via `ssh root@10.1.1.3`; NixOS 26.11.20260801; outbound HTTPS works; plain ext4 iSCSI root; impermanence NOT enabled.
- `f0318cc` (callisto nodejs) **committed AND pushed** on main; live generation predates it (2026-08-22) → first switch makes Node live.
- Laptop rig: opencode 1.18.21 at `~/.opencode/bin/opencode`; auth providers: zai-coding-plan, google, groq, Parallel, opencode-go.
- Fleet sops keys already exist: `zai_api_key`, `groq_api_key`, `dsh_env` (packs Z_AI_API_KEY/GROQ_API_KEY/OPENCODE_API_KEY), `aeon_gh_token`. Precedent for io-owned secrets: `modules/core/crush.nix:117-124`.
- hyperresearch fork: `github.com/belikh/hyperresearch-opencode`, pin **`71b69dd46d461438c61f178eb9d35ad870ed541e`** (HEAD 2026-08-24); `requires-python >=3.11`; crawl4ai NOT needed (moved to extra).
- Precedent modules: `modules/core/crush.nix` (wrapped launcher + activation-installed user config), `modules/services/dsh.nix` (PATH lesson: spawned children need full system PATH; EnvironmentFile read by systemd as root before drop).
- Deploy grammar: push to GitHub, then `ssh -t root@10.1.1.3 'nixos-rebuild switch --flake github:belikh/jupiter-os#callisto'`.
- ⚠️ **PXE rollback caveat**: europa pins `init=` to the last-published toplevel. Any rollback must republish PXE assets (`/var/lib/pxe-netboot/current` on europa) or it won't survive reboot.
- Research report: `/home/io/research/notes/final_report_opencode-config-improve-1c323b.md` (§4 = remediation program).

## 2. WP0 — PARKED (user-side, do not block on it)

Rotate 5 exposed laptop credentials (Proxmox `root@pam!mcp` token FIRST, then z.ai key — update fleet sops `zai_api_key`+`dsh_env` consumers — then UniFi/n8n/HA; all referenced only by dead `new_settings.json` except z.ai). Delete `/home/io/new_settings.json`. Keys currently in fleet sops keep working until rotated; nothing deployed here hardcodes values.

## 3. WP1 — Runtime deps (~30 min)

```bash
# 1. Make committed nodejs live:
ssh -t root@10.1.1.3 'nixos-rebuild switch --flake github:belikh/jupiter-os#callisto'
ssh io@callisto -- node --version   # expect v24.x
```
2. Edit `hosts/callisto/configuration.nix`: add `pkgs.python3` to `environment.systemPackages` (next to existing `pkgs.nodejs`). Eval-check, commit (`callisto: add python3 for hyperresearch venv`), push, switch again.
3. As io on callisto: `npm config set prefix ~/.local`
4. Egress probes: `curl -sI https://pypi.org/simple/ | head -1` and `npm ping`.

**Gate:** node ≥22, python3 present, PyPI+npm reachable.

## 4. WP2 — `modules/core/opencode.nix` (~2h)

Create module gated by `options.jupiter.core.opencode.enable` (house style: explicit mkOption/mkIf, no `with lib;`). Three pieces:

**(a) Wrapped launcher** (copy `crush-wrapped` pattern from `crush.nix:80-88`):
```nix
opencode-wrapped = pkgs.writeShellScriptBin "opencode" ''
  export Z_AI_API_KEY="$(cat ${config.sops.secrets.zai_api_key.path})"
  export GROQ_API_KEY="$(cat ${config.sops.secrets.groq_api_key.path})"
  export OPENCODE_API_KEY="$(cat ${config.sops.secrets.dsh_env.path} | sed -n 's/^OPENCODE_API_KEY=//p')"
  exec "$HOME/.opencode/bin/opencode" "$@"
'';
```
→ into `environment.systemPackages`.

**(b) Activation-installed canonical config** (THE one file):
```nix
system.activationScripts.opencodeConfig.text = lib.strings.optionalString cfg.enable ''
  install -D -m 0644 -o io -g users ${builtinConfig} /home/io/.config/opencode/opencode.json
'';
builtinConfig = pkgs.writeText "opencode.json" (builtins.toJSON { ... });
```

Canonical config contents (single JSON; comments live in the module):
```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "model": "zai-coding/glm-5.3",
  "small_model": "groq/llama-3.1-8b-instant",
  "subagent_depth": 2,
  "permission": {
    "*": "allow",
    "read": { "*": "allow", "*.env": "deny", "*.env.*": "deny", "*.env.example": "allow" },
    "bash": {
      "*": "allow",
      "git push": "ask", "git push *": "ask",
      "curl * -X POST *": "ask", "curl * -X PUT *": "ask",
      "curl * -X PATCH *": "ask", "curl * -X DELETE *": "ask",
      "curl * -d *": "ask", "curl * --data*": "ask",
      "curl * -F *": "ask", "curl * --form *": "ask", "curl * -T *": "ask",
      "curl * --request POST *": "ask", "curl * --request PUT *": "ask",
      "curl * --request PATCH *": "ask", "curl * --request DELETE *": "ask",
      "ssh *": "ask", "scp *": "ask", "sftp *": "ask", "rsync *": "ask",
      "rm -rf /*": "deny", "rm -rf ~*": "deny", "sudo rm *": "deny",
      "nixos-rebuild *": "ask"
    },
    "task": { "*": "allow", "open-ultracode-*": "deny", "ultracode-fusion-*": "deny" },
    "external_directory": "ask",
    "webfetch": "allow",
    "doom_loop": "ask",
    "cloudflare_execute": "ask"
  },
  "provider": {
    "zai-coding":  { "npm": "@ai-sdk/openai-compatible", "name": "Z.AI coding plan",
      "options": { "baseURL": "https://api.z.ai/api/coding/paas/v4", "apiKey": "{env:Z_AI_API_KEY}" },
      "models": { "glm-5.3": { "limit": { "context": 1000000, "output": 131072 } } } },
    "groq":        { "npm": "@ai-sdk/openai-compatible", "name": "Groq",
      "options": { "baseURL": "https://api.groq.com/openai/v1", "apiKey": "{env:GROQ_API_KEY}" },
      "models": { "llama-3.1-8b-instant": { "limit": { "context": 131072, "output": 32768 } } } },
    "opencode-go": { "npm": "@ai-sdk/openai-compatible", "name": "OpenCode Go",
      "options": { "baseURL": "https://opencode.ai/zen/go/v1", "apiKey": "{env:OPENCODE_API_KEY}" },
      "models": { "kimi-k2.7-code": { "limit": { "context": 262144, "output": 262144 } },
                  "minimax-m3":     { "limit": { "context": 1000000, "output": 131072 } } } }
  },
  "mcp": { "cloudflare": { "type": "remote", "url": "https://mcp.cloudflare.com/mcp" } },
  "plugin": [ "/home/io/.local/share/open-ultracode/.opencode/plugins/open-ultracode.ts",
              "@parallel-web/opencode-plugin" ]
}
```
NOTE: model ids must be verified against live catalogs during install (`opencode models` / dsh settingsFile already lists glm-5.3 under z.ai coding plan — match its exact provider/model spelling). Schema-probe watcher/compaction keys via `opencode debug config`; add `"watcher": {"ignore": ["**/node_modules/**","**/.git/**","**/research/raw/**"]}` ONLY if resolved schema confirms the key name.

**(c) sops declarations** in callisto configuration.nix (match crush.nix pattern):
```nix
sops.secrets.zai_api_key  = { owner = "io"; mode = "0400"; };
sops.secrets.groq_api_key = { owner = "io"; mode = "0400"; };
# dsh_env: widen readership — owner stays dsh OR set owner="io"; group="users"; mode="0400".
# VERIFY dsh still starts after switch (systemd reads EnvironmentFile as root pre-drop, but confirm by observation).
```
If `zai_api_key`/`groq_api_key` lack io-readable paths today, reuse ONLY `dsh_env` for all three keys via the launcher's sed extraction instead of adding new sops entries. Simpler is fine.

**(d) Install opencode binary as io:** run the official installer pinned to 1.18.x → `~/.opencode/bin/opencode`; `opencode --version` must print 1.18.x.

Wire `jupiter.core.opencode.enable = true;` into `hosts/callisto/configuration.nix`.

## 5. WP3 — Deploy + config gates (~30 min)

`make check` → commit/push → on-host switch. Gates:
```bash
ssh io@callisto -- opencode debug config | jq '{model, small_model, permission}'
```
- pins present; `.env` deny survives; NO blanket string; providers resolve `{env:}` refs
- Scratch session: `git push` prompts; `pytest`/`true` silent
- `systemctl status dsh` healthy after ownership change

## 6. WP4 — Hyperresearch + FULL vault migration (~2h, as io)

```bash
git clone https://github.com/belikh/hyperresearch-opencode.git ~/Projects/hyperresearch-opencode
cd ~/Projects/hyperresearch-opencode && git checkout 71b69dd46d461438c61f178eb9d35ad870ed541e
python3 -m venv .venv && .venv/bin/pip install -e .
cd ~ && ~/.opencode/bin/opencode 2>/dev/null; ~/Projects/hyperresearch-opencode/.venv/bin/hyperresearch init
rsync -a LAPTOP:/home/io/research/ ~/research/
rsync -a LAPTOP:'.hyperresearch/hyperresearch.db .hyperresearch/config.toml' ~/.hyperresearch/
rsync -a LAPTOP:.hyperresearch/templates/ ~/.hyperresearch/templates/ 2>/dev/null || true
~/Projects/hyperresearch-opencode/.venv/bin/hyperresearch sync && repair
~/Projects/hyperresearch-opencode/.venv/bin/hyperresearch profile use full
```
(Replace LAPTOP with its tailnet/LAN address or do push/pull via an intermediate.) Then:
- Confirm `~/.config/opencode/plugins/hyperresearch-lockdown.js` exists (rendered by `install --global` if not carried over — run `hyperresearch install --global` if agents/skills/command are missing)
- Gates: `status -j` ok:true · `lint -j` clean · `run verify opencode-config-improve-1c323b -j` passes · smoke `fetch https://opencode.ai/docs/agents/ --tag wp-smoke -j` writes a real note
- **Laptop is now a frozen archive. No further writes there.**

## 7. WP5 — Agent roster (~1.5h, as io)

Target ≈20 visible global agents (+4 jupiter-os project agents load only inside the repo checkout):
1. Write 5 merged core markdown agents in `~/.config/opencode/agents/`: `build` (primary), `planner` (=planner+architect), `reviewer` (=9 reviewers, language-detecting), `build-resolver` (=6 resolvers, toolchain-sniffing), `tester` (=tdd-guide+e2e-runner). Descriptions ≤120 chars, imperative trigger form.
2. `hyperresearch install --global` renders 15 pipeline roles + 19 skills + `/hyperresearch` command + ops block into AGENTS.md. Post-pass: trim any description >120 chars. NEVER create project-level skill copies.
3. Ultracode family (10 roles): installed by open-ultracode installer to `~/.local/share/open-ultracode/` + agent files; hidden from Task menu by the task-deny globs already in the config (WP2). Fallback if globs don't hide them on 1.18.x (probed in WP2): shorten those descriptions to one line.
4. Gate: `opencode debug config | jq '.agents'` (or session `/agents`) shows ~20 visible; ultracode entries absent from menu but @-mention invokable.

## 8. WP6-lite — Vault durability (~15 min)

europa: add `tank/services/callisto-root` to sanoid snapshot datasets (tiny separate PR + europa switch). Optional follow-up: monthly tar of `~/research` to europa.

## 9. WP7-lite — Browser-lane prep (~15 min)

Add sops secret `cloudflare_browser_run_token` (io-owned 0400) + export `CLOUDFLARE_BROWSER_RUN_TOKEN`/`CF_ACCOUNT_ID` in `opencode-wrapped`. No consumer yet — lights up natively when upstream issue [#2](https://github.com/belikh/hyperresearch-opencode/issues/2) merges (`git pull && pip install -e .` picks it up).

## 10. Final acceptance sweep

**EXECUTED 2026-08-26.** End-state below; deviations recorded inline.

- [x] WP1 gates: node v24.19.0, python3 3.14.7, PyPI+npm egress 200 (observed)
- [x] WP2: module committed (`e0790a4`, nix-ld follow-up `b0da1ad`); binary 1.18.x
      installed (self-updated 1.18.22→**1.18.23**, still V1); canonical config
      activation-installed; sops io-owned secrets rendered; model ids verified
      live (re-verified again today — see groq rotation note)
- [x] WP3 gates: debug-config pins present, `.env` deny survives, task-deny
      globs resolve, providers resolve `{env:}` refs, dsh healthy post-ownership-change
- [x] WP4: fork @ `71b69dd` cloned, venv (py3.14) editable-installed,
      hyperresearch v0.10.0.post1; vault + db/config/templates + `~/Projects/ha-strategy`
      rsynced (laptop = frozen archive since 10:45 AEST); sync/repair ok;
      `profile use full`; status ok; run verify ok; fresh-fetch smoke wrote a real
      note (two earlier attempts correctly DUPLICATE_URL'd — dedup proof)
      ⚠️ lint residual (inherited from laptop vault, NOT migration damage):
      2 errors (provenance islands ×3 notes, locus-coverage ×2 unwritten),
      ~56 uncurated drafts, stale-index/instruction warnings. Historical record;
      fabricating the missing pieces retroactively was deliberately refused.
- [x] WP5: roster = 30 registered agents — 5 merged core (build/planner/
      reviewer/build-resolver/tester) + 15 hyperresearch pipeline roles
      (install --global; descriptions trimmed ≤120) + 10 ultracode family
      (spawn-denied via task globs, one-line descriptions). `/hyperresearch`
      command registered. Menu-visibility check pending first interactive session.
- [x] WP6-lite: sanoid snapshots LIVE on the real volume — hourly/daily/monthly
      `rpool/services/callisto-root@autosnap_*` exist as of 11:00 (docs' tank/
      services/callisto-root is a pre-migration leftover; noted in module).
- [x] WP7-lite: `cloudflare_browser_run_token` generated blind (openssl →
      sops set --value-stdin, never displayed), io-owned 0400, rendered;
      wrapper exports CLOUDFLARE_BROWSER_RUN_TOKEN + CF_ACCOUNT_ID.
- [x] Discord bridge (Phase-2 pulled forward at io's request): packaged
      remote-opencode 1.5.3 (`pkgs/discord-opencode-bridge`), io systemd unit
      w/ wrapper-PATH spawn; bot logged in as jupiterOS bot#0952, 15 slash
      commands deployed, /setpath+/opencode chain spawns opencode serve
      successfully. Fixes en route: upstream README's flat config shape is
      wrong (code wants `.bot{}` nesting); NO_UPDATE_NOTIFIER; ~/.config chowned.
- [x] End-to-end model round-trip ON HOST: `opencode run -m
      opencode-go/kimi-k2.7-code` → `ACCEPTANCE-SMOKE-OK` rc=0 through the
      deployed wrapper (keys→nix-ld→provider all proven).
- [x] Zero plaintext credentials: `grep -rEn "sk-|Bearer" ~/.config/opencode/`
      matches are only `{env:VAR}` reference syntax and provider NAMES, no values.
- [x] Promotion & reboot-safety: switch executed at each step; PXE pin
      republished and verified == booted/current generation (`van59p2n…`);
      europa carries the sanoid change.

**Known constraints (external, not deployment faults):**
1. z.ai coding-plan quota exhausted until **2026-08-27 07:44** — default
   glm-5.3 routing unblocks itself at reset; routing config verified correct.
2. Groq title-gen blocked by org-level **8000 TPM free tier** vs ~33k-token
   title prompts (direct gpt-oss-20b curl works). Fix = Dev Tier upgrade
   (user decision) or tolerate missing titles. Model-id itself corrected today:
   groq rotated llama-3.1-8b-instant out of the key's catalog overnight.
3. opencode auto-updater moved the per-user binary 1.18.22→1.18.23 (still V1).

**Incident record (2026-08-26 ~04:47–07:51 AEST):** first switches activated
fleet bump `b68bdb6` (nixpkgs 148bab9→ffb3c9b incl. kernel 6.18.44) which had
sat unactivated on main since Aug 22. Runtime activation killed callisto twice
(journal ends mid `switch-to-configuration`; iSCSI root yanked mid-userspace-swap).
Recovered via cold-boot into published assets; lesson encoded: major input bumps
on iSCSI-rooted hosts need boot-based cutovers, never runtime switch/test;
`--builders ""` on-host; pin flake revs during incident iterations (mutable-ref
staleness shipped one stale render).

## 11. Deferred — Phase 2 (do NOT build now)

- **Discord**: `modules/services/discord-opencode-bridge.nix` running github.com/bevibing/remote-opencode as io systemd service; token/clientId/guildId/allowedUserIds via sops; needs user's Discord portal inputs. Full design preserved in conversation history of 2026-08-24 planning session; re-plan if lost.
- **V2 evaluation**: install `opencode2` side-by-side; unblock conditions: plugin-API freeze + `experimental.subagent_depth` parity confirmed. Test against scratch project only.
- **WP0 rotation** (user) · **Infra MCP restore** (Proxmox/UniFi/HA least-privilege local servers w/ fresh scoped creds) · **usage-counter plugin** · **@parallel-web plugin version pin audit**.

## 12. Reference links

- Report: `/home/io/research/notes/final_report_opencode-config-improve-1c323b.md`
- Run artifacts: `/home/io/research/runs/opencode-config-improve-1c323b/` (loci.json, comparisons.md, interim notes = committed positions)
- Upstream features: belikh/hyperresearch-opencode issues #1 (Postgres), #2 (Kitesurf browser lane)
