# europa Stage 4 — live progress

Autonomous run: building europa's `btver2`-tuned closure via `make rebuild-world`
(pallene on an ephemeral BinaryLane server), then switching europa to it.

This file is appended to as the run progresses so progress is visible on GitHub.
Times are AEST. The build log itself is at `/tmp/jupiter-build/rebuild-world.log`
on the dev machine (not committed).

## What "Stage 3 ✅" actually was (fixed before this run)

The runbook claimed all runtime prerequisites were real and committed. They were not:

1. **GIT_REF dead code** — `scripts/binarylane-build-server.sh` defines `GIT_REF`
   but never passes it as cloud-init user-data; pallene fell back to
   `defaultRef = "dashboard-v2"`, which has no europa host → build would fail.
   Fixed: `defaultRef = "feat/europa-phase2-tuned-closure"` (committed 3ec86b4).
2. **microarch invalidates cache.nixos.org** — runbook Step 0 ("switch europa to
   Phase 2, still substitutes from cache.nixos.org") is impossible: `gcc.arch=btver2`
   tags the whole closure `gccarch-btver2`, which cache.nixos.org doesn't have.
   Fixed: broke the cycle with a *local* (uncommitted) `microarch=null` switch so
   europa took the baseline Phase 2 closure from cache.nixos.org and brought the
   tunnel + attic substituter live. Restored to `btver2` for the final switch.
3. **cloudflare_cert placeholder** — 3-char AccountTag/TunnelSecret, no TunnelID.
   Fixed: real `~/.cloudflared/<uuid>.json`; created the missing DNS route
   `attic.jupiter.au → <uuid>.cfargotunnel.com`.
4. **attic cache private** — `jupiter-os` `is_public=0` → europa substituter 401.
   Fixed: flipped `is_public=1` (DB-level; this is server state, not in config).
5. **attic_push_token had no push permission** — pallene couldn't upload.
   Fixed: minted a real push token via `atticd-atticadm make-token --push jupiter-os`.

End-to-end verified before spending money: pushed a unique test path, europa
substituted it from `localhost:8080/jupiter-os` (confirms the `jd6…` trusted key);
R2 creds list `jupiter-os-pallene-iso`; BinaryLane token returns 200.

## Status / timeline (AEST)

- run launched (background, detached) — `make rebuild-world`
- pallene ISO built ✓ → uploaded to R2 ✓
- BinaryLane server-create FAILED: `cpu-8thr` "Unable to find a suitable host"
  (shared-tier capacity stockout in melbourne). Catalog lists it available but
  no physical host free. Retrying with `BL_SIZE_SLUG=std-8vcpu` (32GB, better
  for 8 parallel nix jobs). If that also fails, escalate to a `ded-*` host or
  Sydney.
- `std-8vcpu` created OK (server 639488) but ISO upload from R2 **errored in 2s**.
  Root cause: `aws s3 presign` with no `--region` emits a SigV2 URL (`AWSAccessKeyId=`)
  which R2 rejects (401, R2 is SigV4-only). Orphaned server destroyed to stop billing.
  Fix: `scripts/upload-pallene-iso-r2.sh` now passes `--region auto` (forces SigV4).
- Re-run succeeded: server 639489 created, ISO uploaded (SigV4, action completed),
  attached + rebooted. **pallene is now booted and building europa's btver2 closure.**
  (Note: the driver logs "clone @ dashboard-v2" — that's its dead-code `GIT_REF` var;
  pallene actually clones the ISO's baked `defaultRef = feat/europa-phase2-tuned-closure`.)

## Build phase (long; ETA 1–3h on 8 vcpu)
Monitoring: BinaryLane server 639489 (alive = building, 404 = done/self-destructed),
and attic for europa's toplevel path. Next step after self-destruct: restore
`microarch=btver2` locally and `nixos-rebuild switch` europa to substitute the
tuned closure from `localhost:8080`.
- 05:16 AEST: ~1h into build — server 639489 active, no europa paths in attic yet (push happens at end of build)
