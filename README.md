# jupiter-os (bootstrap rebuild)

Declarative, ZFS-backed NixOS monorepo for the Jupiter home/lab
infrastructure — **rebuilt from scratch, one machine at a time**.

The previous iteration of this repo (preserved on the
`archive/full-fleet-reference` branch, and used as the reference for this
rebuild) designed the entire 10-host fleet up front and was never
successfully built end-to-end. The main reasons:

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

## Registered hosts

Seven hosts are wired into the flake today:

- **The 4 TCx Wave dashboard kiosks** (one per room): **amalthea**
  (jupiter-bedroom — the bootstrap host and canonical template), **metis**
  (kitchen), **adrastea** (office), **thebe** (robbie-room). Impermanent ZFS
  root (erase-your-darlings), Cage + Chromium kiosk session, stock nixpkgs
  kernel — everything comes from cache.nixos.org. amalthea, thebe, and metis
  are physically installed and live. adrastea shares the same kiosk profile
  (its own hostName/hostId/dashboard URL/disk), registered and CI-green but
  awaiting its real install (placeholder disk and sops key).
- **europa** (HPE MicroServer Gen10) — the ZFS NAS + data hub, live at
  `10.1.1.2`. Runs the **bdver4-tuned** closure — CI-built and pushed to
  Harmonia, which europa substitutes ahead of cache.nixos.org (the one
  justified microarch exception; see `hosts/europa/configuration.nix`). Also
  runs the PXE server callisto netboots from (ganymede's role in the old
  design, moved here since ganymede isn't registered), the jupiterOS Arcade
  ROM pipeline, and the Harmonia binary cache (`:5000`, fed by CI over the
  tailnet — see `docs/ci-harmonia-push-runbook.md`).
- **callisto** — netboot compute node (HP EliteDesk 800 G4 DM, i5-8500T
  Coffee Lake 6c/6t, 64GB RAM; the box destroyed NVMe drives repeatedly, so
  root lives on ext4-over-iSCSI instead of local disk), the fleet's shared
  Nix remote builder (`modules/core/build-machines.nix` is currently disabled
  fleet-wide; europa delegates inline to callisto only — see CLAUDE.md) — and
  the fleet's MQTT broker (every kiosk's ha-agent publishes here, moved from
  amalthea 2026-07-24). Live at `10.1.1.3` on a kexec-netboot closure europa
  PXE-serves. `jupiter.build.microarch = "skylake"` is **enabled** — CI builds
  and pushes the skylake-tagged closure to Harmonia.
- **pallene** — Kamatera VPS build server (persistent, disk-booted). Not a
  fleet member; the raw disk image is built with `nix build .#pallene-raw`,
  compressed, and served to Kamatera's image library via a public URL
  (the `vps-image-server` module that served it was removed 2026-08-17 as
  an unwired orphan — recover from git history if the flow returns).

```bash
make check              # nix flake check --no-build (eval every registered host)
make build-all          # build the 4 kiosk closures explicitly
make test-<host>        # build & boot a host in an interactive QEMU VM
make boot-smoke-<host>  # headless CI-style boot test
make fmt                # format all Nix (nixfmt-rfc-style); fmt-check to verify
```

### Installing onto a real unit

(Worked example for the kiosk siblings, since amalthea is already installed.
Identical flow was used for amalthea originally.)

1. Set the real OS disk in `hosts/<name>/configuration.nix`
   (`jupiter.storage.disk` — a `REPLACE-ME` placeholder only on
   adrastea today; amalthea/metis/thebe are installed with real disks. disko
   will WIPE that device).
2. Boot the unit from a NixOS installer/rescue image with SSH up, then from
   a machine holding this repo:

   ```bash
   nix run github:nix-community/nixos-anywhere -- --flake .#metis root@<installer-ip>
   ```

3. After first boot, derive the host's age key from its SSH host key and
   re-key the secrets so it can decrypt `io_password`:

   ```bash
   ssh metis 'cat /etc/ssh/ssh_host_ed25519_key.pub' | nix run nixpkgs#ssh-to-age
   # replace metis's placeholder recipient in .sops.yaml with that key, then:
   sops updatekeys secrets/secrets.yaml
   ```

   (The kiosk works without secrets — only the `io` admin login password
   comes from sops.)

## Growing the fleet

Bring machines back one at a time, in dependency order, porting their config
from `archive/full-fleet-reference` and re-adding flake inputs only when a
machine actually needs them:

1. **amalthea** — proves the flake, storage profiles, impermanence, sops,
   kiosk stack. ✅ live
2. **thebe** — shares the kiosk profile (its own hostName/hostId/dashboard
   URL/disk, plus USB Wi-Fi). ✅ live
3. **metis** — shares the kiosk profile (its own hostName/hostId/dashboard
   URL/disk). ✅ live
4. **adrastea** — shares the kiosk profile. registered; awaiting physical
   install
5. **europa** (NAS + data hub) — live at `10.1.1.2`, **bdver4-tuned**
   (CI-built, served via Harmonia). Also PXE-serves callisto (ganymede's role
   in the old design; moved here since ganymede isn't registered), runs the
   Harmonia binary cache, and hosts the jupiterOS Arcade ROM pipeline.
6. **callisto** (netboot, fleet Nix remote builder and MQTT broker — HP
   EliteDesk 800 G4 DM, i5-8500T Coffee Lake 6c/6t, 64GB RAM). ✅ live at
   `10.1.1.3` on a kexec-netboot closure, root over ext4-iSCSI; daemon tuning
   (`cores=6 max-jobs=1`) and **`jupiter.build.microarch = "skylake"`**
   (CI-built, served via Harmonia). MQTT broker moved here from amalthea
   2026-07-24.
7. **ganymede** (always-on services: resolver/DNS, tunnels) — then pin
   `networking.nameservers` back to it in `modules/common.nix`.
8. **himalia** (laptop, home-manager), gaming/branding/terranix/edge-device
   layers — each restores its own inputs.

Rules that keep this buildable:

- **No custom kernels on ZFS hosts.** The stock `linuxPackages` default is
  the one ZFS always supports and the cache always has.
- **No microarch tuning** without a private build cache that serves what
  cache.nixos.org can't once `gcc.arch` is set. (europa's `bdver4` and the
  callisto/kiosk `skylake` tunings are the justified exceptions — CI-built and
  served via Harmonia.)
- **A new input must be justified by a registered host** that uses it.
- **Every registered host is a flake check** — `make check` evals it, CI
  builds the closures. Don't register scaffolds that can't build.

## Layout

- `flake.nix` — inputs (nixpkgs, `nixpkgs-unstable`, disko, impermanence,
  sops-nix, ha-linux-agent, `jovian`), `mkHost`, `nixosConfigurations`,
  checks, formatter, dev shell.
- `hosts/<name>/configuration.nix` — per-host config. Hosts are named after
  Jupiter's moons.
- `modules/` — reusable NixOS modules behind the `jupiter.*` options
  namespace (`jupiter.storage.profile`, `jupiter.core.impermanence`,
  `jupiter.dashboardKiosk`, `jupiter.build.microarch`, …), organized into
  `boot/`, `core/`, `desktop/`, `gaming/`, `network/`, `services/`, `storage/`.
  `common.nix` at the modules root is the base layer. Hosts opt in via
  toggles.
- `secrets/secrets.yaml` — sops-nix + age (recipients in `.sops.yaml`);
  carried over unchanged from the previous tree.
- `scripts/` — `boot-smoke.sh` (headless QEMU boot assertion used by CI),
  `amt.py` (Intel AMT power control for the kiosks),
  `tcxwave-touch-wake.py` (touch-screen wake helper).
