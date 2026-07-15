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
- 06:17 AEST: ~2h into build — server 639489 still active; btver2 closure rebuilds the full gcc/glibc bootstrap so this is the heavy part; no push yet (expected)
- 07:21 AEST: server 639489 self-destructed after ~3h BUT attic has 0 europa paths → pallene exited non-zero (build or push failed). Logs lost with the server. Investigating: can I build locally for real-time logs?
- 07:40 AEST: re-launched with log-capture (commit on build-server.nix); server 639523 created (std-8vcpu), booting into the new ISO. Will upload /tmp/jupiter-build.log to attic on exit.
- 08:41 AEST: ~1h into log-capture run — server 639523 active, building (no push/log yet)
- 09:41 AEST: ~2h into log-capture run — server 639523 still active (previous run failed at ~3h, so the next hour is the critical window)
- 12:03 AEST: 3rd run — added R2-based log upload (robust, independent of nix/attic). Server 639562 created (std-8vcpu), booting. When it exits, log -> r2://jupiter-os-pallene-iso/logs/. Previous 2 runs self-destructed ~3h with 0 paths + no log (attic-based upload also failed).
- 13:05 AEST: 3rd run ~1h — server 639562 active, building; R2 log uploads on exit
- 15:22 AEST: ROOT CAUSE FOUND (from the recovered /tmp/jupiter-build.log the user pulled via the BinaryLane console): the build never ran — 0 CPU. Two bugs:
-   1. 'experimental Nix feature nix-command is disabled' — pallene is mkIsoHost (skips common.nix, which sets experimental-features), so nix build died INSTANTLY. FIXED: build-server.nix now sets [nix-command flakes].
-   2. 'hostname: command not found' broke the log upload AND self-destruct, so the server couldn't destroy itself → idle billing until manual destroy. FIXED: dropped the hostname dep — log name is timestamp-only; self-destruct lists servers and destroys every pallene-run-*.
-   Also added timeouts on git clone (10m) + attic login (2m) so a network hang can't strand a server, and console=ttyS0 on the ISO for serial visibility.
- LOCAL VALIDATION: booted the fixed ISO in QEMU (serial console via tmux). The build-server service now RUNS nix build (CPU-saturated the 2vcpu/3GB VM into OOM-thrashing) — i.e. it builds now instead of the old instant 0-CPU fail. The box is too small to complete a build, but the fix is confirmed. The real BinaryLane run (8vcpu/32GB/340GB) is now de-risked.
