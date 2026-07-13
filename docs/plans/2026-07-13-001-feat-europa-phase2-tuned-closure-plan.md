---
title: "Europa Phase 2 — btver2-Tuned Closure via BinaryLane Build Server"
date: 2026-07-13
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
origin: ~/.gemini/antigravity-cli/brain/f4db6849-3bdb-4e2b-88e1-a3cdb8c493f3/europa-plan.md (Phase 2 appendix)
---

## Goal Capsule

Switch europa from its Phase 1 untuned closure (PR #15, built from `cache.nixos.org`) to a `btver2`-tuned closure compiled by the ephemeral BinaryLane build server (`pallene`), pushed to europa's own Attic cache, and substituted back onto europa. This is the deliberate, mitigated exception to the repo's "no microarch tuning" rule — the private Attic cache exists precisely to serve the closure that `cache.nixos.org` can no longer provide once `gcc.arch = "btver2"` is set.

**Authority:** User decisions override all. Master branch modules are the design reference; port pieces now that the machine that needs them (europa) is registered and the build server that compiles for it (pallene) is being brought up.

**Stop conditions:** `jupiter.build.microarch = "btver2"` is set on europa, `nix flake check --no-build` passes for all hosts, the `pallene` ISO host registers in the flake with a `pallene-iso` build output, europa's substituter config points at its own Attic, and the rebuild-the-world module + Makefile targets are in place. The actual first build/switch is a runtime ops step, not a plan stop condition (it requires the Cloudflare tunnel live + a real BinaryLane run).

## Product Contract

### Summary

Port the "rebuild the world" workflow from `master`: the `jupiter.build.microarch` option, the BinaryLane build-server module, the `pallene` ephemeral ISO host, and the Cloudflare Tunnel that lets the remote build server reach europa's LAN-bound Attic. Wire europa to consume its own Attic as a substituter — a gap `master` never closed.

### Problem Frame

Phase 1 (done) bootstraps europa untuned so it builds purely from `cache.nixos.org`. The europa hardware (Opteron X3216, Puma core, ISA-equivalent to Jaguar) is a 2015-era low-power APU whose baseline nixpkgs closure leaves real performance on the table. Tuning to `btver2` recompiles the whole closure for this exact CPU — but doing so invalidates `cache.nixos.org` for europa's entire closure (every derivation is tagged `requiredSystemFeatures = ["gccarch-btver2"]`). The only way to serve a tuned closure is a private binary cache. europa already runs `atticd` (Phase 1); Phase 2 completes the loop: a remote builder compiles the tuned closure, pushes it to that Attic, and europa pulls it back.

### Requirements

- R1. A `jupiter.build.microarch` option (nullOr str) that sets `nixpkgs.hostPlatform.gcc.{arch,tune}` when non-null, ported from `master:modules/core/build-tuning.nix`.
- R2. europa sets `jupiter.build.microarch = "btver2"`.
- R3. `make check` aligned to `nix flake check --no-build` (matches CI) so a microarch-tuned europa doesn't break local full-build.
- R4. A Cloudflare Tunnel module runs `cloudflared` on europa, exposing `atticd` at `attic.jupiter.au`, using the existing `cloudflare_cert` sops secret.
- R5. europa consumes its own Attic as a nix substituter (`nix.settings.substituters` + `trusted-public-keys`), gated so it only activates when the attic service is enabled.
- R6. The BinaryLane build-server module (`modules/services/build-server.nix`) ported from master: clones the repo at a git ref, builds registered hosts' closures, pushes to Attic, self-destructs via the BinaryLane API on any exit path, with a 4h force-destroy safety-net timer.
- R7. The `pallene` ephemeral ISO host registered in the flake, importing only the build-server module + the installer CD base (no common.nix, no storage profile, no impermanence).
- R8. A `pallene-iso` flake package output (`config.system.build.isoImage`) buildable via `make pallene-iso`.
- R9. Secrets for the build server: `binarylane-api-token` and `attic-push-token`, committed as placeholders and materialized from sops by the `make pallene-iso` target (master's pattern — ISO build needs the plaintext at build time, no runtime host key to decrypt against).
- R10. `make pallene-iso` and `make rebuild-world` Makefile targets.

### Scope Boundaries

- **In scope:** build-tuning option, europa microarch + substituter consumer config, cloudflare-tunnel module on europa, build-server module, pallene ISO host + flake registration + iso output, build-server secrets + placeholders, Makefile targets, `make check` alignment.
- **Out of scope (ops, at first run):** the actual first `make rebuild-world` execution, real BinaryLane API token acquisition, the Cloudflare dashboard tunnel/hostname configuration, the one-time `attic cache create` that mints the cache public key. These are documented as bootstrap steps, not implemented.
- **Out of scope (future hosts):** applying microarch tuning to the kiosks (they stay untuned), iSCSI/replication (callisto/ganymede unregistered), a separate tunnel host (ganymede) — europa runs cloudflared itself because no other server host is registered.

### Deferred to Follow-Up Work

- Moving cloudflared off europa onto ganymede once ganymede is registered (europa-as-tunnel-host is a Phase 2 expedient, not the long-term topology).
- Tuning the other fleet hosts (kiosks are `skylake` on master but stay untuned here until their real CPUs are confirmed and a build-server run is justified).
- restic offsite of `tank/services/attic` (deliberately excluded — attic state is reproducible).

---

## Planning Contract

### Key Technical Decisions

- **KTD1. `make check` → `--no-build`.** Once europa sets `gcc.arch = "btver2"`, its closure derivations carry `requiredSystemFeatures = ["gccarch-btver2"]`. Local `make check` (currently `nix flake check`, a full build) fails on any dev machine without that system feature and without the Attic configured. CI's `check` job already uses `--no-build` and is unaffected. Aligning `make check` to `--no-build` matches CI and is the only viable option once any host is microarch-tuned. The real build verification for kiosks stays in CI's boot-test matrix; europa's build verification moves to the build server. Tradeoff: local full-build of all hosts is lost — accepted.
- **KTD2. cloudflared runs on europa, not ganymede.** Master ran the tunnel on ganymede (unregistered here). europa is the only always-on server host on this branch, so it runs cloudflared itself, tunneling its own atticd out. Deviation from master topology, justified by fleet state; deferred follow-up moves it back to ganymede.
- **KTD3. europa substitutes from `http://localhost:8080`, not the tunnel URL.** europa IS the attic server, so its own substituter points at localhost (no tunnel roundtrip). The build server and any future roaming hosts use `https://attic.jupiter.au` via the tunnel. Both URLs serve the same atticd.
- **KTD4. The attic cache public key is runtime-generated, then baked into config.** `attic cache create jupiter-os` (a one-time ops step once atticd is live) mints the cache's public key. europa's `trusted-public-keys` references it. Bootstrap sequence: atticd live (Phase 1, done) → `attic cache create` → capture pubkey → add to europa substituter config → first build-server run fills the cache → europa `nixos-rebuild switch`. Until the pubkey is captured, the substituter config uses a placeholder and europa stays on the Phase 1 closure.
- **KTD5. pallene secrets baked into the ISO at build time, not decrypted at runtime.** The ephemeral build server has no persistent host key for sops-nix to decrypt against (it never survives one run). Following master: placeholder files are committed so eval always succeeds; `make pallene-iso` materializes the real plaintext from sops immediately before the ISO build and deletes it after.
- **KTD6. build-server `hosts` list = `[ "europa" ]` only.** Only europa is microarch-tuned on this branch. The module's `hosts` option defaults to the master fleet list; override to europa-only so the build server doesn't try to build untuned hosts (they'd build fine but waste compute — they substitute from cache.nixos.org already).
- **KTD7. build-server `microarchs = [ "btver2" ]` + `system-features` injection.** The build server must declare `gccarch-btver2` in its own `system-features` or nix refuses to even attempt europa's tuned derivations ("missing system features"). Confirmed hard Nix-level gate on master.

### Sequencing

U1 (foundation) → U2 (tunnel, parallel-eligible with U1) → U3 (europa microarch+substituter, needs U1) → U4 (build-server module, needs U2 for the atticServer URL) → U5 (pallene host, needs U4) → U6 (secrets + Makefile, needs U5). Linear with U1//U2 parallelizable.

---

## Implementation Units

### U1. build-tuning module + make check alignment

**Goal:** Introduce the `jupiter.build.microarch` option (harmless when null) and align local `make check` with CI's eval-only mode.

**Requirements:** R1, R3.

**Dependencies:** none.

**Files:**
- `modules/core/build-tuning.nix` (create — port from `master:modules/core/build-tuning.nix`)
- `modules/common.nix` (edit — add `./core/build-tuning.nix` to imports)
- `Makefile` (edit — change `check:` target from `nix flake check` to `nix flake check --no-build`)

**Approach:**
Port `build-tuning.nix` near-verbatim from master: a `jupiter.build.microarch` option (`types.nullOr types.str`, default null) that, when non-null, sets `nixpkgs.hostPlatform.gcc.arch` and `gcc.tune`. No host sets it yet after this unit — europa gets it in U3. Keep master's CAUTION comment about `-march` only changing what gets built, not what a host will run (SIGILL risk), and the build-server-CPU-must-support-it note. Add the import to `common.nix` so every host sees the option. Change the Makefile `check` target to `--no-build`.

**Patterns to follow:** Module style from CLAUDE.md — explicit `lib.mkOption`/`lib.mkIf`/`lib.types`, `{ config, lib, ... }` arg order, `cfg = config.jupiter.build` let-binding, `options.jupiter.<…>` then `config = lib.mkIf`.

**Test scenarios:**
- Happy path: `nix flake check --no-build` passes (all 5 hosts + pallene once U5 lands) with no host setting microarch.
- Edge case: setting `jupiter.build.microarch = "btver2"` on a throwaway test host evaluates without error and produces `nixpkgs.hostPlatform.gcc.arch = "btver2"` in the evaluated config (verify via `nix eval` against a temporary host, then revert).
- The `make check` target runs `nix flake check --no-build` (confirm the Makefile change took; a full-build `nix flake check` would now be opt-in via a separate `make build-all` target, which already exists).

**Verification:** `make check` completes as eval-only; the build-tuning option is present (`nix eval .#nixosConfigurations.amalthea.config.jupiter.build.microarch` → null).

### U2. Cloudflare Tunnel module on europa

**Goal:** europa runs cloudflared, exposing its atticd at `attic.jupiter.au` so the remote build server can push and future roaming hosts can pull.

**Requirements:** R4.

**Dependencies:** none structural (europa's atticd from Phase 1 must be running for the tunnel to actually proxy traffic, but the module itself is independent).

**Files:**
- `modules/services/cloudflare-tunnel.nix` (create — adapted from `master:modules/network/cloudflared.nix`)
- `hosts/europa/configuration.nix` (edit — import the module)

**Approach:**
A `jupiter.services.cloudflareTunnel` module with `enable` toggle + a `tunnelId` option (the tunnel's UUID, an ops value from the Cloudflare dashboard). When enabled, runs `services.cloudflared` with the tunnel credentials from the existing `cloudflare_cert` sops secret (already in `secrets/secrets.yaml`) and an ingress map routing `attic.jupiter.au` → `http://localhost:8080` (atticd's port), default `http_status:404`. Master sourced the tunnel ID + ingress from `lib/site.nix` (absent here) — inline a minimal ingress map in the module rather than introducing a site lib. europa imports it and enables it.

**Patterns to follow:** The Phase 1 attic-server module's option/style (`modules/services/attic-server.nix`); sops secret consumption pattern (`config.sops.secrets.<name>.path`).

**Test scenarios:**
- Happy path: with the module enabled, `nix eval .#nixosConfigurations.europa.config.services.cloudflared.enable` → true; the tunnel ingress map contains the attic.hostname → localhost:8080 rule.
- Edge case: with `enable = false` (default), no cloudflared config is produced (mkIf gates the whole config block).
- Integration: `nix flake check --no-build` passes with europa importing the tunnel module.

**Verification:** europa's evaluated config runs cloudflared with the attic ingress rule; the `cloudflare_cert` sops secret is referenced. Actual tunnel reachability is a runtime/ops confirmation (needs the Cloudflare dashboard side), documented in bootstrap steps.

**Execution note:** This is config/proxying — the proof is config evaluation + a runtime reachability check once the dashboard side is configured, not unit tests.

### U3. europa microarch + substituter consumer config

**Goal:** Flip europa to `btver2`-tuned and wire it to pull its own tuned closure from the local Attic.

**Requirements:** R2, R5.

**Dependencies:** U1 (needs the `jupiter.build.microarch` option).

**Files:**
- `hosts/europa/configuration.nix` (edit — set microarch + substituter config)
- `modules/services/attic-server.nix` (edit — add substituter consumer config gated on `jupiter.services.attic.enable`, or a new small `modules/services/attic-client.nix`)

**Approach:**
Set `jupiter.build.microarch = "btver2"` in europa's configuration.nix (with the hardware-justification comment from master: Puma core, ISA-equivalent to Jaguar, GCC targets as btver2). Add substituter config so europa pulls from its own Attic ahead of cache.nixos.org: `nix.settings.substituters` prepends `http://localhost:8080` (KTD3), and `nix.settings.trusted-public-keys` includes the attic cache's public key. Because the public key is runtime-generated (KTD4), gate the substituter block and use a placeholder public-key value with an explicit comment that it's replaced after `attic cache create`. Prefer folding the consumer config into the existing attic-server module (it already gates on `jupiter.services.attic.enable`) rather than a new file, unless that muddies the server/concern boundary — implementer's call.

**Patterns to follow:** Phase 1 europa configuration.nix's option-setting style; the attic-server module's mkEnableOption/mkIf structure.

**Test scenarios:**
- Happy path: `nix eval .#nixosConfigurations.europa.config.jupiter.build.microarch` → `"btver2"`.
- Happy path: `nix eval` of europa's `nixpkgs.hostPlatform.gcc.arch` → `"btver2"`.
- Edge case: the substituter config is present only when attic is enabled; with attic disabled, no substituter override (so a non-NAS host isn't pointed at a nonexistent localhost:8080).
- Integration: `nix flake check --no-build` passes with europa now btver2-tuned (eval is system-feature-agnostic; only building needs gccarch-btver2).

**Verification:** europa evaluates as btver2-tuned; its substituter list includes localhost:8080 with the attic cache trusted. The actual first switch is a runtime step (needs the cache populated by the build server first).

### U4. BinaryLane build-server module

**Goal:** Port the "rebuild the world" module: clone the repo at a git ref, build closures, push to Attic, self-destruct unconditionally.

**Requirements:** R6.

**Dependencies:** U2 (the `atticServer` URL `https://attic.jupiter.au` must be reachable — the module references it as config).

**Files:**
- `modules/services/build-server.nix` (create — port from `master:modules/services/build-server.nix`)

**Approach:**
Port master's module with these adaptations: (a) `hosts` default overridden to `[ "europa" ]` (KTD6 — only europa is tuned); (b) `microarchs` default `[ "btver2" ]` (KTD7); (c) `atticServer` set to `https://attic.jupiter.au`; (d) drop references to `lib/site.nix`/`docs/roadmap.md` that don't exist here, keep the self-destruct trap, the 4h force-destroy timer, the parallel per-host build+push, and the `system-features` injection. Keep the `bl-api` curl wrapper and the cloud-init user-data git-ref mechanism (flag the cloud-init-datasource-on-custom-ISO uncertainty from master's comment as an open question — if unverified, the ref falls back to a baked default). The module is imported only by pallene (U5), never by a normal fleet host.

**Patterns to follow:** master's `modules/services/build-server.nix` structure (let-bound scripts, options block, mkIf config block, systemd service + timer).

**Test scenarios:**
- Happy path: `nix flake check --no-build` passes with the module present (it's not imported by any registered host until U5 wires pallene).
- Edge case: with `enable = false` (default), no systemd services, no system-features override, no environment.packages added.
- Integration: once U5 imports it on pallene, `nix eval .#nixosConfigurations.pallene.config.jupiter.services.buildServer.microarchs` → `[ "btver2" ]` and `system-features` contains `gccarch-btver2`.

**Verification:** module evaluates cleanly; when enabled, produces the jupiter-build-server oneshot service + force-destroy timer + the gccarch-btver2 system-feature. Actual build/push/self-destruct is a runtime confirmation on a real BinaryLane run.

### U5. pallene ephemeral ISO host + flake registration

**Goal:** Register the build server as a bootable ISO host in the flake, with a `pallene-iso` build output.

**Requirements:** R7, R8.

**Dependencies:** U4 (pallene imports the build-server module).

**Files:**
- `hosts/pallene/configuration.nix` (create — port from `master:hosts/pallene/configuration.nix`)
- `flake.nix` (edit — register pallene with a bare mkHost variant that skips common.nix, and add `pallene-iso` package output)
- `secrets/pallene-secrets/binarylane-api-token.placeholder` (create)
- `secrets/pallene-secrets/attic-push-token.placeholder` (create)

**Approach:**
Port pallene from master: an installer-CD-based config importing only `(modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix")` + the build-server module. No common.nix (pallene isn't a real fleet member — no impermanence, no sops host module, no storage profile). Use master's `realOrPlaceholder` pattern so eval always finds the secret files (placeholders committed; `make pallene-iso` swaps in real plaintext from sops around the build). Register in flake.nix: master's `mkHost` takes a single path, so add a pallene-specific path but it must NOT import common.nix — this likely needs a second mkHost variant or an explicit modules list (master's mkHost took `[ ]` extra-modules for pallene; the current branch's mkHost takes only a path, so adjust mkHost to accept an optional override, or add a dedicated `mkIsoHost`). Add `pallene-iso = self.nixosConfigurations.pallene.config.system.build.isoImage;` to `packages.x86_64-linux` (NOT in `checks` — the ISO is a package, not a per-host check). Drop master's chaotic-nyx neutralization (that flake input doesn't exist on this branch).

**Patterns to follow:** master's `hosts/pallene/configuration.nix` realOrPlaceholder let-binding; the current branch's mkHost lexical-closure pattern (flake.nix).

**Test scenarios:**
- Happy path: `nix eval .#nixosConfigurations.pallene.config.networking.hostName` → `"pallene"`.
- Happy path: `nix build .#pallene-iso` produces an ISO (this one DOES build — pallene is untuned, so it substitutes from cache.nixos.org; confirm it's not gated behind the btver2 system-feature).
- Edge case: placeholders exist so `nix flake check --no-build` doesn't fail on missing secret paths.
- Integration: pallene's evaluated config imports the build-server module and enables it with `atticServer = "https://attic.jupiter.au"`.

**Verification:** `nix eval` of pallene succeeds; `nix build .#pallene-iso` produces an ISO image path. Booting it on BinaryLane and observing a build+push+self-destruct is a runtime confirmation.

**Execution note:** ISO builds are heavy — prefer confirming `nix eval` + that the isoImage build path evaluates, then a full `nix build .#pallene-iso` as the proof.

### U6. Secrets + Makefile targets

**Goal:** Wire the build-server secrets (placeholders + sops entries) and the `pallene-iso` / `rebuild-world` Makefile targets.

**Requirements:** R9, R10.

**Dependencies:** U5 (pallene-iso target references the flake output); U4 (secrets referenced by the module).

**Files:**
- `secrets/secrets.yaml` (edit — add `binarylane_api_token` and `attic_push_token` keys via sops)
- `secrets/pallene-secrets/binarylane-api-token.placeholder` (create — dummy content, from U5)
- `secrets/pallene-secrets/attic-push-token.placeholder` (create — dummy content, from U5)
- `Makefile` (edit — add `pallene-iso` and `rebuild-world` targets)

**Approach:**
Add the two new secrets to `secrets/secrets.yaml` via sops (encrypted to all existing recipients, same as the attic token added in Phase 1). Commit placeholder files alongside so pallene eval resolves without the real plaintext. Port master's Makefile `pallene-iso` target: materialize the real plaintext from sops into `secrets/pallene-secrets/`, run `nix build .#pallene-iso`, then clean up the plaintext (so it never lands in the store/git). Add a `rebuild-world` target that boots the ISO on BinaryLane via the API (thin wrapper around the bl-api mechanism, or document the manual BinaryLane boot-from-ISO step if API boot-from-custom-ISO isn't wired). Keep `pallene-iso` runnable without the real secrets (placeholders) so `nix flake check --no-build` and a dry ISO build both work.

**Patterns to follow:** master's Makefile `pallene-iso`/`rebuild-world` targets; the sops-edit pattern used to add `attic_server_token_secret` in Phase 1.

**Test scenarios:**
- Happy path: `nix flake check --no-build` passes with the new sops keys present and placeholders committed.
- Happy path: `make pallene-iso` (without real secrets) builds an ISO using placeholder tokens (the ISO is structurally valid even if the baked tokens are dummies).
- Edge case: the placeholder files are gitignored-or-not consistent with master's pattern (placeholders ARE committed so eval works; real files are gitignored).
- Integration: the two new sops keys decrypt under the existing recipient set (no `.sops.yaml` change needed — recipients already include all hosts).

**Verification:** `make pallene-iso` produces an ISO; `make check` (--no-build) still passes; the new secrets exist in the sops tree.

---

## Verification Contract

- **Primary gate:** `make check` (now `nix flake check --no-build`) passes for all registered hosts including the new `pallene` entry. This is eval-only — it proves every config evaluates, not that europa's btver2 closure builds (that's the build server's job).
- **ISO build:** `nix build .#pallene-iso` produces an ISO (pallene is untuned, substitutes from cache.nixos.org).
- **europa tuned eval:** `nix eval .#nixosConfigurations.europa.config.nixpkgs.hostPlatform.gcc.arch` → `"btver2"`.
- **Substituter wired:** `nix eval .#nixosConfigurations.europa.config.nix.settings.substituters` includes the localhost attic URL.
- **Runtime (NOT a plan gate — ops, at first run):** cloudflared tunnel live → `attic cache create jupiter-os` mints pubkey → pubkey added to europa config → `make rebuild-world` (or manual BinaryLane boot) builds + pushes europa's closure → europa `nixos-rebuild switch` substitutes from its own Attic → europa running btver2-tuned closure.

## Definition of Done

- [ ] `modules/core/build-tuning.nix` exists and is imported in `modules/common.nix`; `jupiter.build.microarch` option evaluates.
- [ ] `make check` runs `nix flake check --no-build`.
- [ ] `modules/services/cloudflare-tunnel.nix` exists; europa imports + enables it; uses the existing `cloudflare_cert` secret.
- [ ] europa sets `jupiter.build.microarch = "btver2"`.
- [ ] europa's substituter config includes its own Attic (localhost:8080) + the cache public key (placeholder until `attic cache create` runs).
- [ ] `modules/services/build-server.nix` exists (ported, hosts=europa, microarchs=btver2, atticServer=attic.jupiter.au).
- [ ] `hosts/pallene/configuration.nix` exists; registered in `flake.nix` with a non-common.nix mkHost path; `pallene-iso` package output present.
- [ ] `secrets/pallene-secrets/*.placeholder` committed; `binarylane_api_token` + `attic_push_token` added to `secrets/secrets.yaml`.
- [ ] `make pallene-iso` and `make rebuild-world` Makefile targets present.
- [ ] `make check` (—no-build) passes for all hosts including pallene.
- [ ] `nix build .#pallene-iso` succeeds (untuned, from cache.nixos.org).
- [ ] No abandoned-attempt code in the diff; master comments referencing absent files (lib/site.nix, docs/roadmap.md) cleaned up.

## Open Questions

- **Q1 (cloud-init on custom ISO):** Master's build-server module reads the target git ref from the BinaryLane cloud-init datasource, with a comment flagging it UNVERIFIED for custom-booted ISOs. If cloud-init doesn't deliver user-data to a custom ISO, the ref falls back to a baked default (acceptable — rebuild the ISO when the ref matters). Confirm at first runtime; not a plan blocker.
- **Q2 (Cloudflare tunnel config):** The `tunnelId` and the `attic.jupiter.au` DNS/hostname must exist in the Cloudflare dashboard (routed to this tunnel). The `cloudflare_cert` secret is the tunnel credentials JSON. Confirm the cert corresponds to an active tunnel configured for the attic hostname at first run.
- **Q3 (mkHost for pallene):** The current branch's `mkHost` injects common.nix's closure (sops, impermanence, disko, ha-linux-agent) via a lexical closure. pallene must NOT get common.nix. Decide at implementation: extend mkHost with an optional `extraModules`/skip-common flag, or add a dedicated `mkIsoHost`. Master passed `[ ]` as extra-modules to suppress the common import.
- **Q4 (attic cache public key bootstrap):** europa's substituter `trusted-public-keys` cannot be filled until `attic cache create jupiter-os` runs (after atticd is live, which it is from Phase 1). The first build-server run therefore can't be consumed by europa until this key is captured and committed. Document the bootstrap ordering explicitly; the config ships with a placeholder key + a comment.

## Sources & Research

- `master:modules/core/build-tuning.nix` — the `jupiter.build.microarch` option (near-verbatim port).
- `master:modules/services/build-server.nix` — the BinaryLane rebuild-the-world module (self-destruct trap, force-destroy timer, parallel build+push, system-features injection).
- `master:hosts/pallene/configuration.nix` — the ephemeral ISO host (realOrPlaceholder secret pattern, installer-CD base).
- `master:modules/network/cloudflared.nix` + `master:hosts/ganymede/configuration.nix` — tunnel reference (ran on ganymede there; this plan runs it on europa per KTD2).
- `master:flake.nix` — `pallene-iso` package output + the `mkHost ./hosts/pallene [ ]` extra-modules pattern.
- `master:Makefile` — `pallene-iso` + `rebuild-world` targets.
- Phase 1 (PR #15) — europa registered, atticd running on tank/services/attic, `attic_server_token_secret` in sops, `cloudflare_cert` already in secrets.yaml.
- User decisions (this session): `make check` → `--no-build`; Cloudflare Tunnel for build-server→Attic connectivity.
