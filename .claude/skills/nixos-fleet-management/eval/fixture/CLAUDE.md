# CLAUDE.md (fixture excerpt)

A stand-in fleet, shaped like jupiter-os. Two hosts: `amalthea` (canonical
template) and `metis` (sibling).

## Buildability rules

- No custom kernels - the stock kernel package is what every host is built
  against.
- No microarch tuning - it invalidates the binary cache for the closure.
- Everything must build/substitute cleanly; `make check` is the eval gate.

## Common commands

```
make update          # bump the nixpkgs input (simulated)
make check            # eval-only check across both hosts (simulated)
make boot-smoke-<host> # canary boot test for one host (simulated)
```

Note: this fixture simulates Nix rather than running it, so these commands
finish in seconds and need no network or real `/dev/kvm`.
