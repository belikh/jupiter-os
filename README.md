# jupiter-os (bootstrap rebuild)

Declarative, ZFS-backed NixOS monorepo for the Jupiter home/lab
infrastructure — **rebuilt from scratch, one machine at a time**.

The previous iteration of this repo (preserved on the `master` branch, and
used as the reference for this rebuild) designed the entire 10-host fleet up
front and was never successfully built end-to-end. The main reasons:

- **Microarch-tuned closures** (`nixpkgs.hostPlatform.gcc.arch = "skylake"`)
  invalidated the public binary cache for the whole system — Chromium, the
  kernel, everything compiled from source, gated on a private attic cache
  that didn't exist yet.
- **Custom kernels everywhere** (fleet-wide CachyOS via chaotic-nyx,
  `linuxPackages_latest` on the kiosks, a `mkForce linuxPackages_7_0` patch
  in the ZFS layer to hold it all together) — three modules fighting over the
  kernel, none of them the cached, ZFS-supported default.
- **Heavy, fragile inputs** (chaotic-nyx, jovian, home-manager, deploy-rs,
  terranix, a private `ha-linux-agent` flake) injected into every host, so
  nothing evaluated unless everything fetched.
- **Cross-host coupling** (PXE closure wiring, the backup-hub scan over all
  hosts, deploy-rs checks) meant building one machine required evaluating
  the whole fleet.

This tree inverts that: start from the **smallest real machine**, prove it
builds/boots/deploys, then grow.

## Bootstrap host: amalthea

A Toshiba TCx Wave 6140-E45 dashboard kiosk (jupiter-bedroom). Impermanent
ZFS root (erase-your-darlings), Cage + Chromium kiosk session, stock nixpkgs
kernel — everything comes from cache.nixos.org.

```bash
make check            # nix flake check — builds every registered host
make build-all        # build the amalthea closure explicitly
make test-amalthea    # build & boot it in an interactive QEMU VM
make boot-smoke-amalthea  # headless CI-style boot test
make fmt              # format all Nix (nixfmt-rfc-style)
```

### Installing onto the real unit

1. Set the real OS disk in `hosts/amalthea/configuration.nix`
   (`jupiter.storage.disk` — currently a REPLACE-ME placeholder; disko will
   WIPE that device).
2. Boot the unit from a NixOS installer/rescue image with SSH up, then from
   a machine holding this repo:

   ```bash
   nix run github:nix-community/nixos-anywhere -- --flake .#amalthea root@<installer-ip>
   ```

3. After first boot, derive the host's age key from its SSH host key and
   re-key the secrets so it can decrypt `io_password`:

   ```bash
   ssh amalthea 'cat /etc/ssh/ssh_host_ed25519_key.pub' | nix run nixpkgs#ssh-to-age
   # replace amalthea's placeholder recipient in .sops.yaml with that key, then:
   sops updatekeys secrets/secrets.yaml
   ```

   (The kiosk works without secrets — only the `io` admin login password
   comes from sops.)

## Growing the fleet

Bring machines back one at a time, in dependency order, porting their config
from `master` and re-adding flake inputs only when a machine actually needs
them:

1. **amalthea** (this tree) — proves the flake, storage profiles,
   impermanence, sops, kiosk stack.
2. **metis / adrastea / thebe** — clones of amalthea (different
   hostName/hostId/dashboard URL). Trivial once amalthea is on hardware.
3. **ganymede** (always-on services: resolver/DNS, PXE, tunnels) — then pin
   `networking.nameservers` back to it in `modules/common.nix`.
4. **europa** (NAS) — restores the `jupiter.backup` auto-replication wiring
   that was stripped from `modules/storage/zfs-profiles.nix`.
5. **callisto** (diskless PXE), **himalia** (laptop, home-manager), gaming/
   branding/terranix/edge-device layers — each restores its own inputs.

Rules that keep this buildable:

- **No custom kernels on ZFS hosts.** The stock `linuxPackages` default is
  the one ZFS always supports and the cache always has.
- **No microarch tuning** until a trusted build cache exists and is proven.
- **A new input must be justified by a registered host** that uses it.
- **Every registered host is a flake check** — `nix flake check` builds it,
  CI boot-tests it. Don't register scaffolds that can't build.

## Layout

- `flake.nix` — inputs (nixpkgs, disko, impermanence, sops-nix), `mkHost`,
  `nixosConfigurations`, checks, formatter, dev shell.
- `hosts/<name>/configuration.nix` — per-host config. Hosts are named after
  Jupiter's moons.
- `modules/` — reusable NixOS modules behind the `jupiter.*` options
  namespace (`jupiter.storage.profile`, `jupiter.core.impermanence`,
  `jupiter.dashboardKiosk`, …). Hosts opt in via toggles.
- `secrets/secrets.yaml` — sops-nix + age (recipients in `.sops.yaml`);
  carried over unchanged from the previous tree.
- `scripts/boot-smoke.sh` — headless QEMU boot assertion used by CI.
