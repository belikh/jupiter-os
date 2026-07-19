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

## Registered hosts

Six hosts are wired into the flake today:

- **The 4 TCx Wave dashboard kiosks** (one per room): **amalthea**
  (jupiter-bedroom — the bootstrap host, canonical template, and fleet MQTT
  broker), **metis** (kitchen), **adrastea** (office), **thebe** (robbie-room).
  Impermanent ZFS root (erase-your-darlings), Cage + Chromium kiosk session,
  stock nixpkgs kernel — everything comes from cache.nixos.org. Only amalthea
  is physically installed; the siblings are clones of amalthea minus the
  broker role (different hostName/hostId/dashboard URL/disk), registered and
  CI-green but awaiting their real install (placeholder disks and sops keys).
- **europa** (HPE MicroServer Gen10) — the ZFS NAS + data hub. Phase 1
  untuned closure is live at `10.1.1.2`; Phase 2 (`btver2`-tuned) closure is
  staged on `feat/europa-phase2-tuned-closure` and is the current focus (see
  `docs/europa-bringup-stages.md`).
- **pallene** — the ephemeral BinaryLane build-server ISO host that compiles
  europa's tuned closure and pushes it to attic. Never a persistent fleet
  member; built via `make pallene-iso` / `make rebuild-world`.

```bash
make check              # nix flake check --no-build (eval every registered host)
make build-all          # build the 4 kiosk closures explicitly
make test-<host>        # build & boot a host in an interactive QEMU VM
make boot-smoke-<host>  # headless CI-style boot test
make pallene-iso        # build the disposable build-server ISO
make rebuild-world      # full ephemeral build-server run: ISO → R2 → BinaryLane → attic
make fmt                # format all Nix (nixfmt-rfc-style); fmt-check to verify
```

### Installing onto a real unit

(Worked example for the kiosk siblings, since amalthea is already installed.
Identical flow was used for amalthea originally.)

1. Set the real OS disk in `hosts/<name>/configuration.nix`
   (`jupiter.storage.disk` — currently a `REPLACE-ME` placeholder in the
   three sibling kiosks; disko will WIPE that device).
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
from `master` and re-adding flake inputs only when a machine actually needs
them:

1. **amalthea** — proves the flake, storage profiles, impermanence, sops,
   kiosk stack, MQTT broker. ✅ live
2. **metis / adrastea / thebe** — clones of amalthea minus the broker
   (different hostName/hostId/dashboard URL/disk). ✅ registered; awaiting
   physical install
3. **europa** (NAS + data hub) — Phase 1 untuned closure running at
   `10.1.1.2`; Phase 2 `btver2`-tuned closure in progress on
   `feat/europa-phase2-tuned-closure`. See `docs/europa-bringup-stages.md`.
4. **ganymede** (always-on services: resolver/DNS, PXE, tunnels) — then pin
   `networking.nameservers` back to it in `modules/common.nix`.
5. **callisto** (diskless PXE), **himalia** (laptop, home-manager), gaming/
   branding/terranix/edge-device layers — each restores its own inputs.

Rules that keep this buildable:

- **No custom kernels on ZFS hosts.** The stock `linuxPackages` default is
  the one ZFS always supports and the cache always has.
- **No microarch tuning** until a trusted build cache exists and is proven.
  (europa's `btver2` is the one justified exception — served from its own
  attic via the pallene build server.)
- **A new input must be justified by a registered host** that uses it.
- **Every registered host is a flake check** — `make check` evals it, CI
  boot-tests the kiosks. Don't register scaffolds that can't build.

## Layout

- `flake.nix` — inputs (nixpkgs, disko, impermanence, sops-nix,
  ha-linux-agent), `mkHost` / `mkIsoHost`, `nixosConfigurations`, checks,
  formatter, dev shell.
- `hosts/<name>/configuration.nix` — per-host config. Hosts are named after
  Jupiter's moons.
- `modules/` — reusable NixOS modules behind the `jupiter.*` options
  namespace (`jupiter.storage.profile`, `jupiter.core.impermanence`,
  `jupiter.dashboardKiosk`, `jupiter.build.microarch`, …), organized into
  `boot/`, `core/`, `desktop/`, `network/`, `services/`, `storage/`.
  `common.nix` at the modules root is the base layer. Hosts opt in via
  toggles.
- `secrets/secrets.yaml` — sops-nix + age (recipients in `.sops.yaml`);
  carried over unchanged from the previous tree.
- `scripts/` — `boot-smoke.sh` (headless QEMU boot assertion used by CI),
  `binarylane-build-server.sh` + `upload-pallene-iso-r2.sh` (drive the
  ephemeral build-server cycle), `amt.py` (Intel AMT power control for the
  kiosks), `tcxwave-touch-wake.py` (touch-screen wake helper).
