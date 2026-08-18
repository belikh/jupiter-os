# ADR-0001 — ROM acquisition is bulk-staged on the pool, not on-demand

Date: 2026-07-31
Status: Accepted
Supersedes: issue #30 (on-demand ROM loading)

## Context

Issue #30 chose fetch-on-first-play for 1G1R console ROMs, premised on the
Myrient HTTP mirror (fast single-file GET, a few seconds per game). That
mirror is gone (see `modules/services/arcade-api.nix` header, issue #42 §4).
The only remaining source is Minerva torrents. Per-game fetch from a torrent
(`aria2c --select-file`) needs live peers, dies with the swarm, and the old
service capped each fetch at 30 min (`scripts/arcade-api/main.go`) — an
unworkable "press game → wait" UX.

Meanwhile the exo-launch architecture (issues #40/#41) already proves the
simpler model: bulk-staged trees under `/tank/archive/retro/games/curated/`,
served read-only over NFS with a per-kiosk overlayfs upper
(`modules/desktop/exodos.nix`).

## Decision

Stage 1G1R console sets onto europa's pool the same way the eXo collections
are staged — bulk, once — and surface them as another
`jupiter.arcade.gameDirs` contributor (see `modules/desktop/cartridges.nix`)
with retroarch (already in `modules/desktop/arcade.nix`) as the launcher.
Do NOT revive the `arcade-api` / `bubbletea-game-loader` on-demand fetch
service. Acquisition (aria2, in nixpkgs) is a europa-side provisioning step
owned by `modules/services/rom-acquire.nix`, never a kiosk runtime path.
Downloads are requested fire-and-forget through the fleet aria2 JSON-RPC
daemon (`modules/services/aria2.nix`, port 6800, `scripts/aria2-rpc.sh`), one
RPC submission per system with `dir=<incomingDir>/<sys>` so already-partial
data + `.aria2` resume state in the staging tree is resumed in place. The
acquire oneshot only verifies the submissions landed (GIDs returned); the
daemon completes them in the background and verify (`jupiter-rom-verify`)
skips systems with in-flight `.aria2` control files.

## Consequences

+ No new flake input, no new runtime kiosk service, no custom kernel — the
  cartridge contributor mirrors the working curated-collection pattern.
+ ROMs never enter a nix closure: `nix build`, CI, and `nix flake check`
  need neither ROMs nor keys (the same property sops already has,
  CLAUDE.md). See the boundary rule below.
+ Cartridge ROMs need NO per-kiosk overlayfs (unlike eXo zips): retroarch
  reads them directly and writes saves to a per-kiosk persisted dir, so the
  collection mount is plain read-only NFS.
- Pool grows by the full set whether each title is played or not.
- The deprecated on-demand stack (`scripts/arcade-api/`,
  `modules/services/arcade-api.nix`) can now be deleted rather than retained
  "for revival" — done in this change.

## Boundary rule: in-repo vs on-pool

| IN-REPO (committed; evaluated by `nix flake check`) | ON-POOL ONLY (europa ZFS `/tank/archive/retro/`; never in git) |
|---|---|
| NixOS modules (`arcade.nix`, `cartridges.nix`, `rom-scraper.nix`, …) | ROMs, CHDs, all boxart/screenshot/video images |
| Generator/launch/wrapper scripts (`scripts/*.sh`, the theme) | The Minerva `.torrent` files |
| The Pegasus theme + QML | No-Intro **DAT** files (non-redistributable under No-Intro's terms) |

Why: a Pegasus `file:`/`assets.*`/`launch:` line is *text pointing at* a
path; eval never `stat`s it, so the closure stays content-free. A ROM (or a
`.torrent`, or a non-redistributable DAT) committed to the repo would be a
store path (bloat, or a `fetchurl` drv) and would make fleet eval/CI depend
on material the buildability rules forbid. This mirrors sops (secrets at
activation, not build).

## Legal posture

Torrent acquisition of copyrighted cartridge ROMs is legally grey-to-unlawful
in most jurisdictions. This repository documents *process* only and hosts no
copyrighted content — no ROMs, no `.torrent`/magnet in git. The user obtains
all ROMs themselves. A `LEGAL.md` should record this explicitly (follow-up).
