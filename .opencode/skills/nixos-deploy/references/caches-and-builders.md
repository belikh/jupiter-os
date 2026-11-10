# Caches, substituters, and builders

## Substitution basics

A store path is accepted from a binary cache when it is signed by a trusted
public key, the store URL is marked trusted, `require-sigs = false`, or the
path is content-addressed. The defaults in `nix.conf`:

```ini
substituters = https://cache.nixos.org/
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
```

On NixOS, set these via `nix.settings.substituters` /
`nix.settings.trusted-public-keys`. Notes:

- A cache added without its public key yields signature failures, not silent
  fallback — verify with `nix store verify --store <url> <path>`.
- `nix.settings` values reached via a non-root user need `trusted-substituters`
  (and trusted users) or only root's settings apply.
- The daemon does not read user `nix.conf` files: settings that must affect all
  builds belong in the system configuration.

**Will it substitute or build?** `nix build --dry-run` (or
`nix-store --realise --dry-run`) prints what would be built versus fetched.
`--offline` disables substituters/network lookups and makes cached lookups
authoritative; useful for proving a closure is fully substitutable.

## Copying paths

```bash
nix copy --to ssh://builder /nix/store/<path>        # push
nix copy --from ssh://cache /nix/store/<path>        # pull
nix copy --to ssh-ng://host …                        # full remote store
nix copy --to file:///srv/cache --all                # simple local cache
```

`ssh://` is the legacy limited store; `ssh-ng://` speaks the daemon protocol
and is what builder specifications use. For HTTP caches (harmonia, attic), the
push side is cache-specific tooling, not `nix copy` without a compatible
store URL.

## Self-hosted caches

| Tool | Shape | Notes |
|---|---|---|
| `nix-serve` | smallest | `services.nix-serve` with a signing key; proxy behind nginx |
| harmonia | Rust, HTTP | serves `/nix/store`; sign keys via `signKeyPaths`; optional TLS |
| attic | multi-tenant | S3-compatible storage, server-side signing, LRU garbage collection |

Generate signing keys with `nix-store --generate-binary-cache-key`; the
private key stays on the cache host, the public key goes to every client's
`trusted-public-keys`.

## Distributed builds

```nix
nix.buildMachines = [{
  hostName = "builder";
  systems = [ "x86_64-linux" ];
  maxJobs = 8;
  supportedFeatures = [ "big-parallel" "kvm" "gccarch-skylake" ];
  mandatoryFeatures = [ ];
  sshUser = "nix-builder";
  sshKey = "/etc/nix/builder_ed25519";
}];
nix.distributedBuilds = true;
```

- Matching rule: **every** `requiredSystemFeatures` on a derivation must be in
  the builder's `supportedFeatures`, and every `mandatoryFeatures` of the
  builder must be present on the derivation. A builder without the feature is
  skipped.
- `gccarch-*` tags (CPU-tuning features emitted by nixpkgs when
  `hostPlatform.gcc.arch` is set) mean tuned closures build only where that
  feature is advertised — such paths cannot come from the generic
  `cache.nixos.org`.
- Outputs are **copied back** to the initiating machine after a remote build
  (you will see `copying path … from ssh://builder` in the log). The remote
  builder is a builder, not a cache.
- The Nix daemon (root) performs the SSH, so keys and known_hosts must exist
  for root, not your user. `builders-use-substitutes = true` lets builders
  fetch inputs from their own caches.
- `--max-jobs 0` forbids local builds, forcing remote-only operation.

## CI build-and-push pattern

1. On the runner: `nix build .#nixosConfigurations.<host>.config.system.build.toplevel`.
2. Push the closure to the cache (`nix copy --to ssh-ng://cache`, or the
   harmonia/attic push path).
3. Pin recent outputs so a garbage collector does not delete yesterday's
   build: `nix-store --realise <path> --add-root /nix/var/ci-roots/<name>`.
4. Deploy on the target by substituting: `nixos-rebuild switch --store-path
   /nix/store/<...>-nixos-system-<host>`, or `nix copy --from cache` then
   `switch-to-configuration`.

`post-build-hook` pushes every finished path automatically — but it runs
synchronously in the build loop and **a failing hook stalls or stops the
loop**; treat cache availability as part of the build system's health.
Keeping a fixed number of recent closures rooted (last N main builds) is the
standard rollback-safety net.

## Put it together

Typical failure to avoid: a target host that cannot substitute a closure
begins compiling it locally, on a machine that is too small, mid-deploy. The
prevention is always the same: prove substitution with `--dry-run` and a
`--offline` build *before* deploy, and route anything non-substitutable to a
builder or a cache first.

## Sources

- Nix manual, substituters and `nix.conf`: https://nix.dev/manual/nix/stable/command-ref/conf-file.html (accessed 2026-09-30)
- Nix manual, `nix copy`: https://nix.dev/manual/nix/stable/command-ref/new-cli/nix3-copy.html (accessed 2026-09-30)
- nix.dev, binary cache setup and distributed builds: https://nix.dev/tutorials/nixos/binary-cache-setup and …/distributed-builds-setup (accessed 2026-09-30)
- nix.dev, GitHub Actions CI recipe: https://nix.dev/guides/recipes/continuous-integration-github-actions (accessed 2026-09-30)
- harmonia: https://github.com/nix-community/harmonia; attic: https://github.com/zhaofengli/attic (accessed 2026-09-30)
