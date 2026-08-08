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

### Mechanism — CORRECTED, and proven byte-for-byte

My first reading ("a transfer died at 227 MB and Cloudflare cached the truncated
body") was **wrong**. It could not explain why byte 0 of the cached object is
*mid-file* HTML rather than the NAR header. The real mechanism:

```
789,707,296 (real NAR)  −  227,752,466 (edge object)  =  561,954,830
```

Origin bytes at offset **561,954,830** are **byte-identical** to the edge
object's first 64 bytes (verified with `cmp`). The cached object is the NAR's
**tail**, not a truncated head.

So the sequence was:

1. A transfer of the 790 MB NAR broke at offset 561,954,830.
2. The retry asked for `Range: bytes=561954830-`.
3. **Harmonia answered `200 OK` — not `206 Partial Content`** — with the ranged
   body (verified against europa: `HTTP/1.1 200 OK` + `content-range` + partial
   body; upstream `nar.rs` uses `HttpResponse::Ok()` and never sets
   `PARTIAL_CONTENT`).
4. Cloudflare took a `200` as a *complete representation* and stored the tail as
   the whole object, stamped with the 1-year TTL from the `/nar/*` rule.
5. Every request since gets the tail, which begins mid-file → `bad archive`.

**Root cause of the poisoning is harmonia's missing 206**, which is upstream
PR [#1139](https://github.com/nix-community/harmonia/pull/1139) — open,
mergeable, one line, unmerged as of 2026-08-09. europa's harmonia has the bug.

Cloudflare's 512 MB ceiling (Free/Pro/Business; 5 GB Enterprise —
[docs](https://developers.cloudflare.com/cache/concepts/default-cache-behavior/#cacheable-size-limits))
is a **contributing** factor, not the cause: it is why the 790 MB object was
BYPASS and streamed in the first place, and why the 227 MB tail was small enough
to be judged cacheable.

Verified locally: with #1139 applied the same request returns `206 Partial
Content`; without it, `200`. curl exits 0 in both cases — the malformed response
does not error, it silently yields wrong bytes, which is why this went unnoticed.

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
2. **Patch harmonia with upstream PR #1139 (the 206 fix).** One line, mergeable,
   still open. Until europa has it, *any* interrupted large transfer over *any*
   lossy path can re-poison the CDN the same way, and no Nix client can ever
   successfully resume from europa. This is the fix that addresses the actual
   root cause; everything else is containment.
3. **Purge the poisoned object.** The surgical option is a by-URL purge of the
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

---

# Follow-up 2: interaction with harmonia's native zstd compression

Tested against the patched binary with `enable_compression = true`,
`max_cacheable_nar_size = 1 MiB`, NAR = 28,832,296 B (over threshold):

| request | status | headers |
|---|---|---|
| full, `Accept-Encoding: zstd` | 200 | `transfer-encoding: chunked`, `content-encoding: zstd`, `vary: accept-encoding`, **`cache-control: no-store`** |
| full, identity | 200 | `content-length: 28832296`, **`cache-control: no-store`** |
| range, `Accept-Encoding: zstd` | **206** | `content-length: 4096`, `content-range`, **`content-encoding: identity`**, `cache-control: max-age=31536000` |

Findings:

1. **`no-store` survives compression.** The handler sets Cache-Control before the
   zstd middleware runs, and the middleware only rewrites the body plus
   `Content-Encoding`/`Vary`.
2. **Range responses are never compressed.** The handler forces
   `Content-Encoding: identity` and the middleware skips any response that
   already carries that header — so resume stays byte-exact and is unaffected by
   this option.
3. **Compressed full responses are chunked** (`no_chunking(false)` drops
   Content-Length). That *removes the declared length a cache could validate
   against*, so a truncated compressed stream is if anything **more** likely to
   be stored as complete. Compression makes the size guard more important, not
   less.
4. **The threshold is measured on the uncompressed `nar_size`.** With zstd the
   stored object is the compressed size, so the check is conservative: a NAR that
   would have fit under the CDN limit once compressed may still be marked
   `no-store`. It never under-protects (compressed ≤ uncompressed in practice),
   and the compressed size cannot be known before the stream ends without
   buffering the whole thing. Documented in the README hunk of the patch.

Not currently live for us: europa runs with `enable_compression` unset
(default false) — its narinfos say `Compression: none` and NAR responses carry a
real `content-length`. This matters only if we turn zstd on.

## Follow-up 3: the size option is measured on the wrong number when zstd is on

Demonstrated with `nixos-manual-html`, `enable_compression = true`,
`max_cacheable_nar_size = 10,000,000`:

```
nar_size   = 28,887,072   OVER  the threshold  -> gate fires
compressed =  2,902,413   UNDER the threshold  -> would have cached fine
result: cache-control: no-store
```

A ~10:1 ratio, so the gate refuses caching for an object the CDN would happily
have stored. Scaled up: a 1 GB NAR compressing to 400 MB, threshold 512 MB, is
marked `no-store` even though 400 MB is under Cloudflare's limit. **False
negatives, and at typical text ratios they would apply to nearly every large
path — which defeats having a CDN at all.**

Root of it: the option gates on `nar_size`, but the object the CDN stores is the
*compressed* body. Those coincide only when the response goes out identity.

### The sharp problem

Compressed responses are `transfer-encoding: chunked` — no Content-Length. That
is exactly the case where a cache has no declared length to validate a truncated
stream against, i.e. **where a size guard is most needed** — and also exactly the
case where the guard cannot measure the right number. The option is least
reliable precisely where it would matter most.

### Options

- **A (exact):** apply the threshold only when the response will actually be sent
  identity — `settings.enable_compression && accepts_zstd(req.headers())` decides.
  `accepts_zstd` is currently private in `zstd_body.rs`; making it `pub(crate)`
  is a one-word change. The option then always measures the bytes really sent.
  Cost: no protection at all for compressed responses (whose size is unknowable
  before the stream ends).
- **B (conservative, current):** keep gating on `nar_size`, document it as the
  uncompressed size. Safe direction, but the false negatives above.

Recommend **A** — a config option that silently means a different thing when
compression is enabled is a footgun, and B's protection is illusory anyway (see
"sharp problem").

### Or: question whether the option should exist

With #1139 merged, the range-response poisoning vector is closed outright. The
residual risk is a plain transfer truncated mid-stream and stored as complete —
which a conforming cache will not do when Content-Length is declared (the
identity case). That leaves the compressed/chunked case as the only real gap,
and the size option cannot cover it. So the honest ranking is:

1. #1139 (closes the actual mechanism),
2. keep `/nar/*` off the CDN, or leave compression off so Content-Length is
   always declared,
3. the size option, as belt-and-braces.
