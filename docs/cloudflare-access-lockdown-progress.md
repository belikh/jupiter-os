# Cloudflare Access lockdown — Jupiter Systems

**Account:** `19f62c2ef7861336d274166233ba3a17` (Jupiter Systems)  
**Started:** 2026-08-18  
**Last updated:** 2026-08-18 (scope reversal: iot/ha-mcp returned to public per user)  
**Audit script:** `scripts/cloudflare-access-audit.sh`  
**Reusable policy:** `me` → `b9c394a3-62e9-42e5-8695-7cc2ddfe7ebe` (`email_domain: djr.net.au`, 24h)

## Status

| Gate | State |
|---|---|
| Access apps for all must-secure hostnames | **DONE** (5) |
| Anonymous blocked on live must-secure hostnames | **DONE** (5/5 with DNS) |
| Public hostnames remain public | **DONE** (cache/headscale/rpc) |
| iot/ha-mcp Access removed (out of scope) | **DONE** |
| Dangling DNS cleanup | **DONE** |
| Dead tunnel cleanup | **DONE** |
| Dead Access app cleanup | **DONE** |
| Bar: zero must-secure exposed | **MET** |

**Overall:** locked down. Must-secure set is `dsh`, `aeon`, `nom`, `ariang`, `n8n` — all behind Access (reusable policy `me`, Google IdP). `iot.jupiter.au` and `ha-mcp.jupiter.au` are **out of scope** per user decision and have **no Access app**.

## Decisions (locked)

1. Apply to live account (non-destructive adds + authorized cleanup).
2. `cache.jupiter.au` — **public by design** (Harmonia anonymous Nix substitution).
3. `headscale.jupiter.au` — **public** (user choice; fleet uses `neptune.jupiter.au:8080`).
4. aria2 — secure **`ariang.jupiter.au` only**; leave **`rpc.jupiter.au` public** (RPC secret only).
5. Cleanup dangling DNS, dead tunnels, dead Access apps — **authorized and executed**.
6. **`iot.jupiter.au` and `ha-mcp.jupiter.au` — OUT OF SCOPE** (2026-08-18). Access apps and the Service-Auth `svc-token` policies created for them were **deleted**. They route to the `homeassistant`/`songapp` tunnels without Access, as before.

## Canonical pattern

Self-hosted Access app per hostname, attach reusable policy `me`.  
Refs:

- https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/
- https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/

**Anonymous “blocked” definition (used by audit + manual probes):**

- HTTP `401` / `403`, **or**
- HTTP `3xx` with `Location: https://*.cloudflareaccess.com/...`, **or**
- HTML body markers: `Cloudflare Access` / Sign-in Access page

## Inventory table (live, 2026-08-18 re-probed)

| Hostname | Tunnel | Class | Access app id | Anon HTTP | Notes |
|---|---|---|---|---|---|
| dsh.jupiter.au | jupiter-callisto `85534a9c…` | **secured** | `c8983b2f-a860-4690-b5f1-594cf46e9efe` | **302** → Access | critical |
| aeon.jupiter.au | jupiter-callisto `85534a9c…` | **secured** | `959642de-599e-4f02-a78e-941b8a4a728f` | **302** → Access | DNS CNAME live |
| nom.jupiter.au | songapp/europa `aa1088b8…` | **secured** | `1bd7bd7b-3c2b-4c62-8194-cf9527a7d7e5` | **302** → Access | |
| ariang.jupiter.au | songapp/europa `aa1088b8…` | **secured** | `692a413b-3ffe-47ee-8373-5183c14bb47b` | **302** → Access | aria2 UI only |
| n8n.jupiter.au | homeassistant `dea254e7…` | **secured** | `94e809a5-29e2-4288-8488-fd1d7e50117f` | **302** → Access | |
| iot.jupiter.au | homeassistant `dea254e7…` | **out_of_scope** | — | **200** origin | user decision; no Access |
| ha-mcp.jupiter.au | songapp/europa `aa1088b8…` | **out_of_scope** | — | **403** origin | user decision; no Access |
| cache.jupiter.au | songapp/europa `aa1088b8…` | **public** | — | **200** Harmonia | keep public |
| headscale.jupiter.au | songapp/europa `aa1088b8…` | **public** | — | **400** origin | keep public |
| rpc.jupiter.au | songapp/europa `aa1088b8…` | **public** | — | **404** origin | keep public; RPC secret |

### Healthy tunnels retained

| Tunnel | ID | Status |
|---|---|---|
| songapp (europa) | `aa1088b8-a0e1-4073-8567-6a9bf5fb4bd7` | healthy |
| jupiter-callisto | `85534a9c-2c13-412c-a658-322f7c36edc7` | healthy |
| homeassistant | `dea254e7-ef08-4c90-a219-402eb39c7535` | healthy |

### Out of primary scope (left alone)

| App | Domain | Note |
|---|---|---|
| Kibana | logs.belic.net | proxied origin, already Access |
| node red | nr.belic.net | proxied origin, already Access |
| belic.net | router.belic.net | proxied origin, already Access |
| App Launcher | belic.cloudflareaccess.com | system |
| Warp Login App | belic.cloudflareaccess.com/warp | system |

## Cleanup log

### DNS deleted

| Record | Zone | Was pointing at | Result |
|---|---|---|---|
| images.jupiter.au | jupiter.au | songapp tunnel (no ingress) | deleted |
| home.io.id.au | io.id.au | nonexistent `ec66d522…` | deleted |
| ingress.io.id.au | io.id.au | nonexistent `ec66d522…` | deleted |
| kasm.io.id.au | io.id.au | nonexistent `ec66d522…` | deleted |
| k.io.id.au | io.id.au | nonexistent `ec66d522…` | deleted |
| m.io.id.au | io.id.au | nonexistent `ec66d522…` | deleted |
| nas.io.id.au | io.id.au | nonexistent `ec66d522…` | deleted |
| shell.io.id.au | io.id.au | nonexistent `ec66d522…` | deleted |

### Dead tunnels deleted (no connectors, no remaining DNS CNAMEs)

| Name | ID | Result |
|---|---|---|
| clawdbot-bot | `9a0e6aa3-627d-423f-88f1-4f6e8d2f41e4` | deleted |
| hassio | `8e224baf-d71d-48de-a390-c26c29e4e60c` | deleted |
| kasm | `0825e137-38fa-4cfd-ba96-4c47dfb55a47` | deleted |
| leantime-tunnel | `344a7d75-5062-4b13-885a-0cd02051c806` | deleted |
| n8n-tunnel | `af2d8053-beab-4ccc-b55b-0cec029d984b` | deleted |

### Dead Access apps deleted (no live DNS/service; App Launcher / Warp retained)

| Name | Domain | ID | Result |
|---|---|---|---|
| bot | bot.jupiter.au | `681fcf78-79ca-4ad6-a313-acfb6c0896a6` | deleted |
| ssh bot | ssh.bot.jupiter.au | `c9672674-859a-4d8d-af57-e0f0d0cc5432` | deleted |
| life | life.jupiter.au/capnp | `bc8dd4d1-d45e-4a53-b752-7afc8070c131` | deleted |
| nas | fnas.io.id.au | `f3084a49-ee43-4dc5-83c4-a68d5753e916` | deleted |

### Scope reversal (2026-08-18, user: iot/ha-mcp out of scope)

| Object | ID | Result |
|---|---|---|
| Access app iot.jupiter.au | `31f346d4-12e6-41f8-9519-acf8a4bc8cce` (recreated) | **deleted** |
| Access app ha-mcp.jupiter.au | `a3bb8fdb-c0e4-4d93-b460-917ced26dae4` | **deleted** |
| Reusable policy svc-token | `0b71fdde-c0bc-4ae8-8b54-7ac88dee1edc` | **deleted** (orphaned) |
| Reusable policy svc-token | `3c9f812a-9114-4ad2-a0cc-876257805eff` | **deleted** (orphaned) |

After reversal only one reusable Access policy remains in the account: `me`.

**Retained (pre-existing, not created by this work):** service token `svc` (`5a2153a5-1d03-4c39-90fc-a3cc8fb158fc`, `7d3cfb732e337917503fc7a159ae782a.access`). It grants nothing today — zero `non_identity`/`bypass` policies reference it (the `svc-token` policies that did were deleted). Kept to avoid breaking any unknown reference; if unused, safe to delete via the dashboard.

## Access apps created (this lockdown, final)

| Hostname | App ID | Policy |
|---|---|---|
| dsh.jupiter.au | `c8983b2f-a860-4690-b5f1-594cf46e9efe` | me |
| aeon.jupiter.au | `959642de-599e-4f02-a78e-941b8a4a728f` | me |
| nom.jupiter.au | `1bd7bd7b-3c2b-4c62-8194-cf9527a7d7e5` | me |
| ariang.jupiter.au | `692a413b-3ffe-47ee-8373-5183c14bb47b` | me |
| n8n.jupiter.au | `94e809a5-29e2-4288-8488-fd1d7e50117f` | me |

Create body used (idempotent if re-run: skip when domain exists). Note the **live** apps show `auto_redirect_to_identity: true` and `allowed_idps: ["03f04555-f8f9-4fe5-83c7-18042eada900"]` (Google) — a single-IdP self-hosted app skips the IdP-selection step:

```json
{
  "name": "<hostname>",
  "type": "self_hosted",
  "domain": "<hostname>",
  "session_duration": "24h",
  "auto_redirect_to_identity": true,
  "allowed_idps": ["03f04555-f8f9-4fe5-83c7-18042eada900"],
  "app_launcher_visible": true,
  "policies": [{ "id": "b9c394a3-62e9-42e5-8695-7cc2ddfe7ebe", "precedence": 1 }]
}
```

## Audit script usage

```bash
export CLOUDFLARE_API_TOKEN=…   # Access:Apps, Tunnels, DNS:Read (or broader Zero Trust)
# optional: export CLOUDFLARE_ACCOUNT_ID=19f62c2ef7861336d274166233ba3a17

./scripts/cloudflare-access-audit.sh           # human table; exit 1 if must-secure exposed
./scripts/cloudflare-access-audit.sh --json    # JSON on stdout, table on stderr
./scripts/cloudflare-access-audit.sh --no-probe  # API classification only
```

Classification:

| Class | Meaning |
|---|---|
| `secured` | Access app present **with policy me**; anonymous probe blocked |
| `public` | In known-public list, no Access app |
| `out_of_scope` | User-excluded hostname (iot/ha-mcp); never gated; app present = warning |
| `exposed` | Healthy tunnel DNS, no working Access block — **fail bar if must-secure** |
| `dangling` | CNAME to missing/down tunnel |

Audit hardening (2026-08-18): classification requires the **reusable policy `me`** on the Access app — an app present without `me` is classified `exposed` and fails the bar. Per-app policy enrichment + DNS pagination included.

## Fresh verification evidence (2026-08-18, post-reversal)

Anonymous probes (no cookies / no WARP auth):

```
SECURE (must-secure — Access challenge):
dsh.jupiter.au         code=302 -> belic.cloudflareaccess.com/cdn-cgi/access/login/dsh
aeon.jupiter.au        code=302 -> belic.cloudflareaccess.com/cdn-cgi/access/login/aeon
nom.jupiter.au         code=302 -> belic.cloudflareaccess.com/cdn-cgi/access/login/nom
ariang.jupiter.au      code=302 -> belic.cloudflareaccess.com/cdn-cgi/access/login/ariang
n8n.jupiter.au         code=302 -> belic.cloudflareaccess.com/cdn-cgi/access/login/n8n

OUT_OF_SCOPE (no Access app; origin reachable):
iot.jupiter.au         code=200 (origin)
ha-mcp.jupiter.au      code=403 (origin)

PUBLIC:
cache.jupiter.au       code=200 (Harmonia)
headscale.jupiter.au   code=400 (origin, not Access)
rpc.jupiter.au         code=404 (origin, not Access)
```

Location targets were `https://belic.cloudflareaccess.com/cdn-cgi/access/login/<hostname>?…` with body title `Sign in ・ Cloudflare Access`.

## Remaining gaps / residual risk

1. **`rpc.jupiter.au` remains public** by design — protection is RPC secret only; anyone who obtains the secret can hit the endpoint. Accept per user decision.
2. **`headscale.jupiter.au` remains public** by design — not the fleet control plane (`neptune.jupiter.au:8080`); still a public surface if something sensitive is served there.
3. **`iot.jupiter.au` / `ha-mcp.jupiter.au` are public** (out of scope by user decision). No Access layer — origin auth only (HA login / MCP path token). Audit will warn loudly if an Access app is ever re-added to them.
4. **Origin-side Access JWT validation** (`originRequest.access` + AUD tags) is **not** enabled — tunnels are locally managed by NixOS `cloudflared` (`source: local`), so the edge is the enforcement point. Deferred follow-up: add `originRequest.access` to the NixOS tunnel module + verify tokens at origin.
5. **belic.net proxied apps** — already had Access; not re-audited for policy strength beyond presence.
6. **Audit script requires a local `CLOUDFLARE_API_TOKEN`**; this session applied via the Cloudflare API binding. Run the script with a token for an end-to-end gate.
7. **Authenticated admit not browser-tested** — policy `me` + Google IdP are present and the anonymous challenge works, but a full browser SSO login to one app has not been exercised by a human.

## Timestamps

| Event | When (UTC-ish local) |
|---|---|
| Inventory via API | 2026-08-18 |
| Created 7 Access apps + policy me | 2026-08-18 |
| aeon.jupiter.au DNS CNAME created | 2026-08-18 |
| Deleted 8 dangling DNS records | 2026-08-18 |
| Deleted 5 dead tunnels | 2026-08-18 |
| Deleted 4 dead Access apps | 2026-08-18 |
| Reversal: iot/ha-mcp Access + svc-token policies deleted | 2026-08-18 |
| Audit script hardened (policy-me gate, pagination, out-of-scope) | 2026-08-18 |
| Re-verified anonymous probes | 2026-08-18 |
| Round-2 harsh critic: **VERDICT ship, BLIND_WINNER ours (qualified), bar MET** | 2026-08-18 |

## Round-2 critic dispositions (2026-08-18)

Harsh independent re-judge (adversary subagent, fresh probes + logic trace):

- **Bar met: YES.** All 5 must-secure return `302 → belic.cloudflareaccess.com` anonymously; policy `me` attached to all 5; public/out-of-scope correct; cleanup verified; aeon DNS live.
- **Blind winner: ours (qualified)** — faithful application of the canonical self-hosted-public-app + tunnel + reusable-policy pattern for the decided scope.
- Open items carried:
  1. **CF-R2-1 (medium, schedule next):** no origin-side Access JWT validation (`originRequest.access` + AUD tags). Tunnels are NixOS-managed (`source: local`); add to `modules/services/cloudflare-tunnel.nix` as a follow-up so a tunnel/ingress misroute can't silently reach the origin.
  2. **CF-R2-2 (medium, user):** "admits a logged-in Google Apps user" is policy-proven but not browser-exercised — log into one app (e.g. dsh.jupiter.au) with a `@djr.net.au` Google account to close the admit half.
  3. **CF-R2-3 (medium, user):** audit gate never executed end-to-end — run `CLOUDFLARE_API_TOKEN=… ./scripts/cloudflare-access-audit.sh` (logic dry-run vs live data returns `bar_met=true, exposed=0`).
  4. **CF-R2-8 (low, user):** audit script + this page are untracked — commit+push when the user approves.
  - Resolved this pass: CF-R2-5 (svc token documented as retained), CF-R2-6 (create-body doc now matches live `auto_redirect_to_identity: true`), CF-R2-7 (rpc re-probe returns 404 reproducibly).
