# CI → Harmonia push runbook (issue #63)

GitHub Actions builds the kiosk closures on free `ubuntu-latest` CPU and pushes
them into europa's `/nix/store` over the UDM WireGuard road-warrior; Harmonia
serves that store to the fleet and the next CI run. This replaces the
decommissioned Attic (Harmonia is read-only — it serves a store, it has no push
API — so "push" means `nix copy --to ssh://europa`, not a Harmonia call).

```
GHA ubuntu-latest ──WG(UDM)──▶ europa:22 (jupiter-ci) ──nix copy──▶ /nix/store
                                  │ Harmonia :5000 (read-only) ◀── serves ─── fleet + next CI run
                                  └ GC roots: keep last 3 main builds/host
```

Push is **main-only** (PRs build + boot-smoke but never push — unreviewed code
must not reach the cache). The push is incremental via a Nix `post-build-hook`
(`scripts/ci/post-build-hook.sh` + `scripts/ci/cache-drainer.sh`, ported from
pallene's `build-server.nix`), and the last 3 main builds per host are pinned
as GC roots by `scripts/ci/retain-recent.sh` so europa's `nix.gc` doesn't evict
what CI just populated.

## Prerequisites (ops — do once, before first deploy)

These cannot live in the PR: `secrets/secrets.yaml` is sops-encrypted (needs
your age key), the GitHub Actions secrets live in repo settings, and the UDM WG
peer is a UniFi dashboard step.

1. **Generate the Harmonia signing keypair** (on europa, once):
   ```sh
   nix-store --generate-binary-cache-key jupiter-cache-1 \
     /var/lib/secrets/harmonia.secret /var/lib/secrets/harmonia.pub
   ```
2. **sops** the private key in and remove the dead Attic secrets:
   - add `harmonia_sign_key` (contents of `harmonia.secret`) to `secrets/secrets.yaml`
   - remove `attic_server_token_secret` and `attic_push_token`
   - (`sops secrets/secrets.yaml`, then commit)
3. **Publish the Harmonia public key** (a public value):
   - GitHub Actions secret `HARMONIA_PUBLIC_KEY` = contents of `harmonia.pub`
   - replace the placeholder default of `publicKey` in
     `modules/core/harmonia-substituter.nix` with the same string + commit
4. **Generate the CI SSH keypair** (`ssh-keygen -t ed25519 -f jupiter_ci`):
   - public half → replace the `authorizedKey` placeholder in
     `modules/core/ci-cache-receiver.nix` + commit (it's public)
   - private half → GitHub Actions secret `EUROPA_CI_SSH_KEY`
5. **Runner WireGuard identity.** Two options:
   - **Reuse pallene's peer (deployed choice — no UDM change needed):** the CI
     runner borrows pallene's existing road-warrior identity, so the UDM needs
     NO new peer. Set `WG_RUNNER_PRIVATE_KEY` = the value of the
     `wireguard_pallene_private_key` sops secret, and `WG_RUNNER_ADDRESS` =
     `192.168.5.2/32` (pallene's tunnel IP). Caveat: WG roaming means the UDM
     routes to whichever of pallene/the-runner handshook last, so the two can't
     push concurrently — fine in practice because pallene's build-server path is
     dormant (europa btver2 rolled back) and CI builds are short.
   - **Fresh peer (alternative):** generate a new WG keypair and add it as a UDM
     road-warrior peer (UniFi) with its own tunnel IP (e.g. `192.168.5.7/32`),
     allowed-ips `10.1.1.0/24`. Then `WG_RUNNER_PRIVATE_KEY` = the new private
     key and `WG_RUNNER_ADDRESS` = the IP you assigned.
   - Either way: `WG_UDM_PUBLIC_KEY` = `gw6gm9TpSBFOqifygp8XLfEEDGgebzD4tEFgXCSawE4=` (the UDM's WG pubkey — same one pallene uses) and `WG_UDM_ENDPOINT` = `neptune.jupiter.au:51820`.
6. **Deploy europa** (the Harmonia sign key must be in sops first, or sops-nix
   fails at activation):
   ```sh
   ssh root@europa -- nixos-rebuild switch --flake github:belikh/jupiter-os#europa
   ```
7. **Verify** (from a WG peer or the runner): `curl http://10.1.1.2:5000/nix-cache-info`
   returns the cache-info blob; `ssh jupiter-ci@10.1.1.2 true` succeeds.

## GitHub Actions secrets summary

| Secret | What |
|---|---|
| `HARMONIA_PUBLIC_KEY` | Harmonia cache pubkey (e.g. `jupiter-cache-1:…=`), used in CI's `trusted-public-keys` |
| `EUROPA_CI_SSH_KEY` | private ed25519 key for the `jupiter-ci` user on europa |
| `WG_RUNNER_PRIVATE_KEY` | runner's WG private key |
| `WG_RUNNER_ADDRESS` | runner's WG tunnel IP (`…/32`) |
| `WG_UDM_PUBLIC_KEY` | UDM road-warrior WG pubkey |
| `WG_UDM_ENDPOINT` | `neptune.jupiter.au:51820` |

## Retention (keep last 3)

`retain-recent.sh` writes one symlink per build to
`/nix/var/nix/gcroots/per-user/jupiter-ci/<host>.<sha>` → the toplevel, and
removes all but the newest 3 per host. europa's `nix.gc` then reclaims the
unrooted closures, so Harmonia stops serving them. A rollback to one of the
last 3 main builds substitutes fully from Harmonia; older builds must be
rebuilt.

## Caveats / known follow-ups

- **Deploy-window ordering matters.** Merging this PR makes every fleet host
  (default-on `harmoniaSubstituter`) try `10.1.1.2:5000` first on every nix
  invocation. Until europa is actually redeployed with Harmonia (prereq #6)
  **and** the placeholder `publicKey` is replaced with the real one, hosts pay
  a short `connect-timeout` stall then fall back to cache.nixos.org / reject
  the untrusted narinfos. Do the merge, europa redeploy, and pubkey replace in
  the same change window.
- **Trust model / branch protection.** Whatever lands on `main` gets built,
  `nix copy`'d into europa's store, signed with the Harmonia key, and served to
  the fleet. `main` is therefore under the `protect-main` ruleset (Settings ->
  Rules -> Rulesets): require a PR + the `check` and `build-and-boot-test`
  status checks, block force-push/deletion, 0 required reviews (solo-dev; bump
  to 1 if a collaborator joins). PR runs build+boot but never push, so
  unreviewed code can't reach the cache.
- **Only the 4 kiosks** are in the CI matrix; europa/callisto closures aren't
  CI-pushed yet (callisto is iSCSI-root, europa is the cache host). Add them to
  the matrix when wanted.
- **pallene's build-server push** (`modules/services/build-server.nix`) still
  targets the decommissioned atticd; it's dormant (europa btver2 is rolled
  back) and must be reworked to `nix copy --to ssh://europa` when btver2 is
  re-enabled.
- **europa store growth**: Harmonia serves europa's live store (no separate
  cache dataset like Attic's `tank/services/attic`). Monitor `/nix/store` on
  europa; the keep-3 rotation bounds it but the dataset is now shared with the
  NAS. The old `tank/services/attic` dataset is left in place (removing it is
  destructive; clean up out of band if desired).
