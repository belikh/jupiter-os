# Pegasus Arcade Metadata Deployment Plan

**Status:** Ready for deployment  
**Last Updated:** 2026-07-30  
**Verified:** Field names fixed, directory structure corrected, trap fixture checklist prepared  

---

## Overview

This document describes the complete workflow for deploying the regenerated Pegasus arcade metadata with corrected field names (`assets.box_front:`, etc.) to all jupiter-os kiosks.

The workflow follows the **Pegasus Metadata Transformation** domain (`.claude/domains/pegasus-metadata-transformation.md`) with specific phases:

1. **Extract LaunchBox metadata** (europa, one-time or ad-hoc)
2. **Regenerate Pegasus collections** (europa, via systemd service or manual run)
3. **Deploy fixes to kiosks** (amalthea, thebe, metis, adrastea via flake rebuild)
4. **Verify artwork in Pegasus UI** (per-kiosk, test against trap fixture)

---

## Phase 1: Extract LaunchBox Metadata (Europa)

### Prerequisites
- SSH access to europa
- LaunchBox archive files present at `/tank/archive/retro/games/curated/*/` 
- 7z, unzip, standard Unix tools installed

### Steps

Run the extraction script on europa:

```bash
ssh europa
cd /tank/archive/retro/games
bash /path/to/extract-launchbox-metadata.sh --base-path /tank/archive/retro/games
```

This extracts:
- XML metadata to `{collection}/xml/` (e.g., `exo-dos/xml/MS-DOS.xml`)
- Images to `{collection}/Images-extract/` (boxart, screenshots, logos)

Collections handled:
- `curated-exo-dos` → `exo-dos/xml/MS-DOS.xml`
- `curated-exo-win3x` → `exo-win3x/xml/Windows 3x.xml`
- `curated-c64-dreams` → `c64-dreams/LaunchBox/...`
- `curated-exo-scummvm` → `exo-scummvm/...`

### Verification

```bash
# Check that XML files exist
ls /tank/archive/retro/games/curated/exo-dos/xml/MS-DOS.xml
ls /tank/archive/retro/games/curated/exo-win3x/xml/Windows\ 3x.xml

# Check that images are extracted
ls /tank/archive/retro/games/curated/exo-dos/Images-extract/ | head
```

---

## Phase 2: Regenerate Pegasus Metadata (Europa)

### Option A: Manual Run

```bash
ssh europa
python3 /path/to/generate-arcade-metadata.py \
  --nfs-root /tank/archive \
  --output /tank/archive/retro/metadata/pegasus/collections \
  --assets /tank/archive/retro/metadata/pegasus/assets \
  --collections all
```

### Option B: Systemd Service (if configured)

```bash
ssh europa
systemctl start arcade-metadata-generate.service
systemctl status arcade-metadata-generate.service
journalctl -u arcade-metadata-generate -n 50 --no-pager
```

### Output Structure

After regeneration, the directory structure will be:

```
/tank/archive/retro/metadata/pegasus/
├── collections/
│   ├── curated-exo-dos/
│   │   └── metadata.pegasus.txt       ← games + assets.box_front paths
│   ├── curated-exo-win3x/
│   │   └── metadata.pegasus.txt
│   ├── curated-c64-dreams/
│   │   └── metadata.pegasus.txt
│   ├── curated-exo-if/
│   │   └── metadata.pegasus.txt
│   ├── ... (10 curated collections)
│   ├── 1g1r-nointro-nes/
│   │   └── metadata.pegasus.txt       ← from DAT files, no assets (Myrient mirror)
│   ├── 1g1r-nointro-snes/
│   │   └── metadata.pegasus.txt
│   ├── ... (15 1G1R collections)
│
└── assets/
    ├── curated-exo-dos/
    │   ├── boxart/ → symlinks to Images/Box Front/
    │   ├── screenshots/ → symlinks to Images/Screenshot/
    │   └── logos/ → symlinks to Images/Wheel/
    ├── curated-exo-win3x/
    │   ├── boxart/
    │   ├── screenshots/
    │   └── logos/
    ├── ... (assets for all curated collections)
```

### Verification

```bash
# Check that collection files exist
ls /tank/archive/retro/metadata/pegasus/collections/curated-exo-dos/metadata.pegasus.txt
ls /tank/archive/retro/metadata/pegasus/collections/curated-exo-win3x/metadata.pegasus.txt

# Check that assets are symlinked (should NOT be black/missing)
ls /tank/archive/retro/metadata/pegasus/assets/curated-exo-dos/boxart/ | head

# Verify a sample metadata file structure
head -20 /tank/archive/retro/metadata/pegasus/collections/curated-exo-dos/metadata.pegasus.txt
```

Expected metadata file header:
```
# Generated from MS-DOS.xml
# Collection: eXoDOS
# Emulator: dosbox

collection: eXoDOS
shortname: dos
launch: pegasus-rom-launch {file.path}
directory: /tank/archive/retro

game: Commander Keen
file: games/curated/exo-dos/Commander\ Keen/keen1.zip
developer: Apogee Software
publisher: Apogee Software
genre: Action; Platformer
release: 1990-12-14
summary: A platformer classic from the early 90s
rating: 100%
assets.box_front: games/curated/exo-dos/Images/Box Front/Commander Keen.jpg
assets.screenshot: games/curated/exo-dos/Images/Screenshot/Commander Keen.jpg
assets.logo: games/curated/exo-dos/Images/Wheel/Commander Keen.png
```

---

## Phase 3: Deploy Fixes to Kiosks (Amalthea/Thebe/Metis/Adrastea)

### Constraint: Kiosk OOM on Heavy Builds

**IMPORTANT:** Kiosks have ~7.6GB RAM and will crash/reboot on heavy local compilation. See `memory/jupiter_os_kiosk_build_oom.md`.

Verify that `jupiter.core.buildMachines` is configured to delegate builds to callisto:

```bash
git show HEAD:hosts/amalthea/configuration.nix | grep -A5 "buildMachines"
```

Expected (should see `buildMachines = ...` or default enabled):
```nix
jupiter.core.buildMachines = true;  # Delegate to callisto
```

### Deployment

1. **Commit and push changes** (already done: commits 84df62a, 1265918, ee5adb0, 7a4a845)

   ```bash
   git status  # Should be clean
   git log --oneline -5
   ```

2. **Rebuild amalthea** (delegated to callisto):

   ```bash
   # On amalthea
   sudo nixos-rebuild switch --flake github:Antigravity/jupiter-os#amalthea
   
   # Or from a remote builder (callisto)
   nix flake check --flake /path/to/repo
   nix build --flake /path/to/repo#nixosConfigurations.amalthea.config.system.build.toplevel
   ```

3. **Monitor build** (check callisto isn't overloaded):

   ```bash
   ssh callisto
   nix show-derivation /nix/store/.../drv  # Should show modest memory footprint
   systemctl status nix-daemon
   ```

4. **Verify NFS mount** (after rebuild):

   ```bash
   ssh amalthea
   mount | grep /tank/archive
   ls /tank/archive/retro/metadata/pegasus/collections/ | wc -l  # Should show 25 dirs
   ```

---

## Phase 4: Verify in Pegasus UI (Trap Fixture)

**Reference:** `.claude/domains/GROUND-TRUTH-pegasus-assets.md`

### Test on Each Kiosk

Access the kiosk's Pegasus UI and verify:

#### 1. Collections Appear
- [ ] eXoDOS collection visible in Pegasus menu
- [ ] eXoWin3x collection visible
- [ ] All other curated collections listed
- [ ] All 1G1R collections listed (NES, SNES, PS1, etc.)

**If failing:** Check that game_dirs.txt lists all collection subdirectories.

```bash
ssh amalthea
cat /home/gamer/.config/pegasus-frontend/game_dirs.txt | wc -l  # Should be 25
```

#### 2. Games Appear
- [ ] eXoDOS: ~500+ games listed
- [ ] eXoWin3x: ~600+ games listed
- [ ] Other collections: game counts vary

**If failing:** Check Pegasus logs for parse errors.

```bash
ssh amalthea
tail -50 /home/gamer/.config/pegasus-frontend/lastrun.log | grep -E "ERROR|Parse|metadata"
```

#### 3. **CRITICAL: Artwork Displays (Trap Fixture)**

Select a game from eXoDOS or eXoWin3x and verify:
- [ ] **Boxart image visible** (not black, not missing)
- [ ] **Game details** show summary, developer, etc.
- [ ] **No parse errors** in Pegasus log

**Test cases:**
- eXoDOS: "Commander Keen" → should show Apogee boxart
- eXoWin3x: "Magic Carpet" → should show Bullfrog boxart
- Any 1G1R game: assets not expected (no artwork), metadata only

**If assets are black/missing:** Run trap fixture verification:

```bash
ssh amalthea

# 1. Check metadata file exists and is valid
head -20 /tank/archive/retro/metadata/pegasus/collections/curated-exo-dos/metadata.pegasus.txt

# 2. Check Pegasus discovered it (fresh log)
systemctl restart pegasus  # (or whatever service runs it)
sleep 5
grep "Found.*metadata.pegasus.txt" /home/gamer/.config/pegasus-frontend/lastrun.log

# 3. Test asset path resolution
cat /tank/archive/retro/metadata/pegasus/collections/curated-exo-dos/metadata.pegasus.txt | grep "assets.box_front" | head -1

# 4. Verify target file exists and is readable
# Example: assets.box_front: games/curated/exo-dos/Images/Box Front/Commander Keen.jpg
ls -lh /tank/archive/retro/games/curated/exo-dos/Images/Box\ Front/Commander\ Keen.jpg

# 5. Check NFS mount is read-only (expected)
mount | grep /tank/archive | grep -o "ro\|rw"
```

**Troubleshooting:**

| Symptom | Cause | Fix |
|---------|-------|-----|
| "No metadata files found" | game_dirs.txt points to parent, not subdirs | Update game_dirs.txt to list subdirectories |
| Games appear, assets all black | Symlinks broken or wrong permissions | Verify symlinks resolve: `readlink -f <link>` |
| Games appear, no assets at all | Wrong field names (e.g., `image:` instead of `assets.box_front:`) | Regenerate with fixed script |
| Parse error in Pegasus log | Syntax error in metadata | Check for special characters, encoding |
| Asset paths don't resolve | Mismatch between `directory:` and relative paths | Verify: `directory: /tank/archive/retro` + file path = valid file |

---

## Deployment Checklist

### Pre-Deployment
- [ ] Extract LaunchBox archives on europa (Phase 1)
- [ ] Verify XML files exist at expected paths
- [ ] Script changes committed (84df62a, previous fixes)
- [ ] arcade.nix gameDirs updated with all 25 collections

### Deployment
- [ ] Verify callisto is the build machine (not local kiosk compilation)
- [ ] Rebuild amalthea from updated flake
- [ ] Verify NFS mount is live after reboot
- [ ] Regenerate metadata on europa (manual or systemd service)

### Verification
- [ ] Pegasus shows all 25 collections
- [ ] eXoDOS: 500+ games listed
- [ ] eXoWin3x: 600+ games listed
- [ ] At least one game shows boxart (not black)
- [ ] Logs show no parse errors

### Post-Deployment
- [ ] Deploy to remaining kiosks (thebe, metis, adrastea)
- [ ] Re-run trap fixture on each
- [ ] Document any failures in follow-up issues

---

## Rollback Plan

If artwork doesn't display or collections don't appear after deployment:

1. **Check game_dirs.txt** was updated correctly:
   ```bash
   cat /home/gamer/.config/pegasus-frontend/game_dirs.txt
   ```

2. **Check metadata files exist**:
   ```bash
   ls /tank/archive/retro/metadata/pegasus/collections/curated-exo-dos/metadata.pegasus.txt
   ```

3. **Revert arcade.nix if needed**:
   ```bash
   git revert HEAD~1
   sudo nixos-rebuild switch --flake github:Antigravity/jupiter-os#amalthea
   ```

4. **Re-run trap fixture** to verify fix.

---

## Related Documentation

- `.claude/domains/pegasus-metadata-transformation.md` — Complete workflow reference
- `.claude/domains/GROUND-TRUTH-pegasus-assets.md` — Trap fixture (critical verification)
- `scripts/generate-arcade-metadata.py` — Metadata generator
- `scripts/extract-launchbox-metadata.sh` — LaunchBox extraction helper
- `modules/desktop/arcade.nix` — Pegasus configuration + gameDirs
- `modules/services/arcade-metadata-generator.nix` — Europa systemd service (optional)
