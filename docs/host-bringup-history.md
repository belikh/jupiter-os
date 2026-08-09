# Host bring-up history

Dated operational events for jupiter-os hosts — kept out of `CLAUDE.md` so its
STATUS table stays scannable. **These are events, not current state.** For
current liveness see `CLAUDE.md` → STATUS, and verify empirically (ping/ssh)
before acting; entries older than ~30 days may be stale.

## amalthea — jupiter-bedroom

Bootstrap machine and canonical kiosk template; every other kiosk derives from
its profile.

## metis — kitchen

- **2026-07-20:** installed with a real disk.
- **2026-07-20 → 2026-07-24:** `.sops.yaml` recipient was the install-time
  **placeholder** age key (not derived from metis's real SSH host key). Secrets
  never decrypted there; `ha-linux-agent` crash-looped on the missing MQTT
  password file.
- **2026-07-24:** fixed by swapping in metis's real age key and running
  `sops updatekeys`.

## adrastea — office

Registered and CI-green, but **not yet physically installed**:

- placeholder disk (`REPLACE-ME` diskId);
- placeholder sops age key (not derived from its real SSH host key).

Awaiting physical install (see `.sops.yaml`).

## europa — `10.1.1.2`

HPE MicroServer Gen10 (AMD Opteron X3216 APU, btver2/Puma, 8GB ECC), the ZFS
NAS + data hub + PXE server.

- **btver2 rollback (`e10a46a`, 2026-07):** `jupiter.build.microarch = "btver2"`
  was rolled back to unblock the arcade bring-up (ZFS 2.4.3 / nixpkgs 26.11
  kernel-build issue), with the line left commented-out in
  `hosts/europa/configuration.nix`.
- **btver2 re-enabled:** once the CI→Harmonia push pipeline worked
  end-to-end, europa moved to the **btver2-tuned** closure — CI-built and
  served via Harmonia (`:5000` / `cache.jupiter.au`), substituting ahead of
  cache.nixos.org. The earlier Attic cache was decommissioned (issue #63).

## callisto — `10.1.1.3`

HP EliteDesk 800 G4 DM, i5-8500T Coffee Lake 6c/6t, 64GB RAM. Fleet's shared
Nix remote builder **and** MQTT broker.

- Persistent **ext4 root over iSCSI** on europa's zvol
  (see `hosts/callisto/configuration.nix`,
  `docs/callisto-iscsi-root-provisioning.md`).
- nixpkgs `26.11.20260616.567a49d`.
- **2026-07-24:** confirmed live deploying the **MQTT broker move** (mosquitto
  relocated amalthea → callisto, to decouple the broker from a kiosk's
  impermanent/appliance lifecycle). sops decrypts fine at activation.
- Build-server tuning (`cores=6 max-jobs=1`) is committed in git.
- `jupiter.build.microarch = "skylake"` is **enabled** — CI builds and pushes
  the skylake-tagged closure to Harmonia (same pipeline as europa's btver2).
  Do NOT rebuild callisto locally without verifying Harmonia has it first
  (`nix path-info --substituters http://10.1.1.2:5000 <toplevel>`).

## pallene — Kamatera VPS build server (not a fleet member)

Persistent, disk-booted from a raw image built via `nix build .#pallene-raw`.
Tuned `cores=1 max-jobs=auto` for full-closure rebuilds (many small packages in
parallel) — the inverse of callisto's `cores=6 max-jobs=1` incremental-shared
profile. Migrated from the earlier ephemeral BinaryLane ISO design
(`c478b67`); the old BinaryLane code (`hosts/pallene/configuration.nix`,
`modules/services/build-server.nix` paths, `scripts/binarylane-*`) is orphaned
dead code pending a separate cleanup.

## Roadmap hosts

Age keys present in `.sops.yaml` but **not registered in `flake.nix`**:

- **ganymede** — resolver/services. Its old design roles (PXE serving,
  `cloudflareTunnel`) were temporarily reassigned to europa/callisto pending
  ganymede's registration.
- **himalia** — laptop.
