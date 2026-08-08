# CI build failure — investigation of temp/build_log.txt

Run: ci-europa, 19 tailnet builders + europa coordinator, commit e3e76c2.
Outcome: failed during the **first** host (`europa`); never reached callisto/kiosks.

## Verdict

**europa's store is healthy. The Cloudflare edge in front of `cache.jupiter.au`
is the fault — and the builders should never have been asking it in the first
place.** europa already had every failing path on disk.

## Store corruption is ruled out

- `nix-store --verify` (the #67 store guard, ci-europa.yml:350) ran at
  build_log.txt:44–46 and **exited 0** — the build proceeded to `Building: europa`
  at line 48.
- `bash-interactive-5.3p15` (`cs3b3wwr…`) — the path named as #67's phantom in
  the workflow comment, and listed in the failing narinfo's `References` — serves
  correctly from origin: narinfo 200, NAR magic `nix-archive-1`, full 7,399,424
  bytes matching `NarSize`. The phantom is gone.
- europa **has both failing paths on disk right now**:
  `75h6pcqj…-ghc-9.10.3-doc` and `vyq1sns4…-rustc-1.97.1`.
- europa's own substituters are `http://localhost:5000 https://cache.nixos.org/`
  — it never queried `cache.jupiter.au`. Every CDN line in the log came from the
  **19 builders**, relayed into europa's log by `--builders-use-substitutes`.

## Root cause: `--builders-use-substitutes` (ci-europa.yml:373)

That flag tells each builder to fetch its own inputs. The builders' substituter
list (ci-europa.yml:48) is `https://cache.jupiter.au` — so 19 GitHub runners
pulled multi-hundred-MB NARs through one `cloudflared` process, for paths the
coordinator already had locally and could ship over the tailnet in seconds.

The log's last two lines show the fallback working exactly as it should:

```
copying 5 paths...
copying path '/nix/store/vyq1sns4…-rustc-1.97.1' to 'ssh-ng://runner@100.64.0.253'...
```

These paths are **not on cache.nixos.org** (all three 404) — they are europa-only
(btver2-tuned / unstable). So the builders had exactly one legitimate source:
europa. Routing that through a CDN bought nothing and broke two ways.

## Failure mode 1 — poisoned edge object (`bad archive`)

`ghc-9.10.3-doc`, 24 failures, always the same hash — reproducible, not a flake.

| | `content-range` total | first bytes |
|---|---|---|
| origin `10.1.1.2:5000` | **789,707,296** (matches `NarSize`) | `0d…nix-archive-1` ✅ |
| edge `cache.jupiter.au` | **227,752,466** | `><span>` — mid-file Haddock HTML ❌ |

Edge headers: `cf-cache-status: HIT`, `cache-control: max-age=31536000`.

Mechanism: **Cloudflare's cacheable-size ceiling is 512 MB on Free/Pro/Business**
(5 GB Enterprise) — [docs](https://developers.cloudflare.com/cache/concepts/default-cache-behavior/#cacheable-size-limits).
The full 790 MB NAR is over that and should have bypassed cache entirely. But a
transfer died at 227 MB, and 227 MB **is** under 512 MB — so Cloudflare judged
the truncated body cacheable and stored it, pinned for **one year**. Offset 0 of
the stored object is mid-file HTML, so it isn't even an aligned prefix; Nix's
parser rejects it instantly. Every builder since gets the same garbage with a 200.

## Failure mode 2 — oversize NARs truncate mid-stream (this killed the run)

Nothing cached here; these stream straight through the tunnel.

| path | NAR size | edge |
|---|---|---|
| `rustc-1.97.1` | 1,090,715,504 (1.09 GB) | `cf-cache-status: BYPASS` |
| `zed-editor-1.12.0-vendor` | 2,099,672,904 (2.10 GB) | `cf-cache-status: BYPASS` |

Both >512 MB → BYPASS → streamed through `cloudflared` → `HTTP error 200
(curl error: Transferred a partial file)` at offsets 56,649,119 and 757,899,018.
Nix retries with a `Range` request; the edge answers **502 "Requested range was
not delivered by the server"**; Nix disables the substituter for 60s and the
build dies (build_log.txt:2166–2173).

`fallback = true` rescues neither: the builders were told to *obtain* these
paths, not build them — hence `path '…' is required, but there is no substituter
that can build it`.

## Failure mode 3 — noise, not cause

~102 narinfo timeouts / `SSL routines::unexpected eof` / `Empty reply from
server` — 19 runners concurrently hammering one `cloudflared`. Symptom of the
same architecture. The `Scripted initrd is deprecated … removal in 26.11` eval
warning is unrelated and harmless for now.

## Recommended fixes (none applied)

1. **Take Cloudflare out of the CI path.** Either:
   - point the builders' substituter at harmonia directly over the tailnet —
     **`http://100.64.0.1:5000`** (europa's tailnet IP; verified, and harmonia
     binds `*:5000` so the tailscale0 interface is served). Use the IP, not
     `europa:5000` — that name resolved on my LAN, and MagicDNS resolution from
     the runners is unverified; `10.1.1.2` would additionally require europa to
     advertise `10.1.1.0/24` as an approved subnet route, which it does not.
     Keeps parallel pull, no CDN, no 512 MB ceiling, and matches what CLAUDE.md
     and `modules/core/harmonia-substituter.nix` document as the intended CI
     path; or
   - drop `--builders-use-substitutes` (ci-europa.yml:373) so europa `nix copy`s
     inputs over ssh-ng — the path the log already fell back to successfully.

   Same sites to change either way: `ci-europa.yml:48,200`, `ci.yml:77`,
   `ci-distributed.yml:154,352`.
2. **Purge the poisoned object.** The surgical option is a by-URL purge of the
   single ghc-doc NAR URL; `purge_everything` is the blunt one (Free plan is
   capped at 5 purge requests/min). Edge TTL is stamped at insertion, so editing
   the cache rule does **not** re-stamp it — it must be purged. Zone
   `933a228e1ff71234053c52d9d6308014`.
3. **Stop `/nar/*` from ever being cached truncated again.** The 1-year `/nar/*`
   rule can only ever apply to objects <512 MB anyway; anything larger is a
   pass-through liability. Consider bypassing cache for `/nar/*` outright, or
   keeping the CDN strictly for off-LAN clients that have no tailnet route.
4. **Deploy e3e76c2 to europa.** It still shows `http://localhost:5000` as its
   first substituter — the self-subscription that commit removes.

---

# Follow-up: can harmonia mark >512 MB NARs uncacheable?

**Not today — no such option exists.** Harmonia's full config surface is `bind`,
`workers`, `max_connection_rate`, `priority`, `enable_compression`,
`virtual_nix_store`, `real_nix_store`, `nix_db_path`, `sign_key_paths`,
`tls_cert_path`, `tls_key_path`. Nothing about Cache-Control or size.

The header is hardcoded in `harmonia-cache/src/nar.rs` — `cache_control_max_age_1y()`
at two sites (the range branch, ~line 153, and the full-stream branch, ~line 173).

**A patch would be small and clean:**
- `nar_size` is already in scope at both sites.
- A `cache_control_no_store()` helper already exists and is used elsewhere in the
  same file (404 branches, lines 78/98/109).
- So: a `max_cacheable_nar_size` config option (0/unset = current behaviour),
  and `if nar_size > threshold { no_store } else { max_age_1y }`.

## The catch — it would do nothing for us as currently configured

Cache rule 2 on zone `933a228e1ff71234053c52d9d6308014`:

```
"nix cache: NARs are immutable (content-addressed) - max TTL"
  expression: http.host eq "cache.jupiter.au" and starts_with(uri.path, "/nar/")
  edge_ttl:    { default: 31536000, mode: "override_origin" }   <-- !!
  browser_ttl: { default: 31536000, mode: "override_origin" }
```

`override_origin` means **Cloudflare ignores the origin's `Cache-Control`
entirely.** Per Cloudflare's docs, an Edge TTL that ignores origin cache-control
overrides even `no-store` — the response is cached anyway. So a harmonia patch
emitting `no-store` would be silently discarded at the edge.

**For the patch to have any effect, rule 2 must first change
`mode: override_origin` → `respect_origin`.** That is safe on its own: harmonia
already sends `cache-control: max-age=31536000` for NARs (verified against
origin), so respecting the origin yields the same 1-year TTL for normal NARs —
the rule is currently re-stating what the origin already says.

Order matters: flip the rule to `respect_origin` first (that alone changes
nothing observable), then the harmonia patch starts working.

## Honest limits of this fix

A size threshold shrinks the blast radius but does not close the hole. What
actually happened is that Cloudflare stored a response as *complete* even though
the origin declared `content-length: 789707296` and delivered 227,752,466 bytes.
A conforming cache should never store a short body against a declared length —
something in the `cloudflared` → edge path re-framed it. Any NAR *under* the
threshold can still truncate and poison the same way; large ones are just the
likeliest to.

Zero-code alternative: set `/nar/*` to bypass cache outright. Cloudflare cache
rules cannot match on response size (they run in the request phase), so
size-conditional caching is only expressible at the origin — which is exactly
why the harmonia patch is the right upstream shape.

**Note:** none of this unblocks CI. CI is fixed by taking Cloudflare out of the
builder path (see recommendation 1 above); this hardens the *public* cache for
off-LAN clients.
