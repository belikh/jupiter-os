# nar: add `max_cacheable_nar_size` to mark oversized NARs as `no-store`

## Problem

When harmonia sits behind a CDN, NARs larger than the CDN's maximum cacheable
object size can be **stored truncated and served as if complete**.

Observed on a Cloudflare-fronted harmonia (Free plan, 512 MB cacheable limit):

- `ghc-9.10.3-doc`, NAR size 789,707,296 bytes.
- Origin serves it correctly: `content-length: 789707296`, body begins with the
  `nix-archive-1` magic.
- The edge stored a **227,752,466-byte** object — a transfer that died partway.
  227 MB is under the 512 MB limit, so it was judged cacheable and stored, with
  the `max-age=31536000` harmonia sends for NARs.
- Every subsequent fetch returns that object with `200` + `cf-cache-status: HIT`.
  Byte 0 is mid-file HTML, not a NAR header, so Nix fails with
  `error: bad archive: input doesn't look like a Nix archive` — reproducibly,
  until the entry expires (a year) or is manually purged.

The origin is healthy throughout; only the cached copy is corrupt.

## Why this belongs in harmonia rather than in CDN config

CDN cache rules are evaluated in the **request** phase, so they cannot branch on
the response size — Cloudflare's own guidance for oversized assets is to split
them or upgrade the plan. The response size is known only at the origin, which
makes the origin the only place this is expressible.

## Change

A new config option:

```toml
# 0 (default) = no limit, current behaviour is unchanged
max_cacheable_nar_size = 536870912
```

Above the threshold, a full NAR response is sent with `Cache-Control: no-store`
instead of `max-age=31536000`. `0` means unlimited, matching the existing
convention in `Config` (`max_connections`: "0 keeps the actix default").

Deliberately scoped:

- **Only the full-stream branch is gated.** The `Range` branch is left
  cacheable: a slice is not the size of the whole NAR (a 4 KB range of a 2 GB
  NAR is 4 KB), and it is the path clients use to *resume* an interrupted
  download of exactly these large objects — the last thing that should be
  discouraged.
- Default is off, so existing deployments see no change.

## Verification

`cargo check`, `cargo clippy` and `cargo fmt --check` all clean.
