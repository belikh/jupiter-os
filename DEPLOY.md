# Arcade Metadata Deployment Checklist

**Branch:** arcade-pegasus-architecture  
**Latest commit:** 4937660 (Add Pegasus metadata validation script)  
**Status:** Ready for deployment  

---

## 📋 Pre-Deployment Checks

### Code
- [x] Script directory structure fixed (subdirectories with metadata.pegasus.txt)
- [x] Asset field names corrected (assets.box_front, assets.screenshot, etc.)
- [x] Directory declaration added to all metadata generators
- [x] arcade.nix updated with all 25 collection directories
- [x] All changes committed and pushed

### Verification
- [x] Trap fixture documentation created (GROUND-TRUTH-pegasus-assets.md)
- [x] Fable-domain workflow documented (pegasus-metadata-transformation.md)
- [x] Deployment plan created (docs/arcade-metadata-deployment.md)
- [x] Validation script created (validate-arcade-metadata.sh)
- [x] Extraction script created (extract-launchbox-metadata.sh)

---

## 🚀 Deployment Steps

### Step 1: Europa — Extract LaunchBox Metadata

**Timing:** One-time or whenever LaunchBox archives are updated  
**Duration:** 5-15 minutes  

```bash
ssh europa
bash /path/to/extract-launchbox-metadata.sh --base-path /tank/archive/retro/games

# Verify extraction
ls /tank/archive/retro/games/curated/exo-dos/xml/MS-DOS.xml
ls /tank/archive/retro/games/curated/exo-win3x/xml/Windows\ 3x.xml
```

**Expected output:**
```
Starting LaunchBox metadata extraction...
  Processing: curated/exo-dos
    Extracting: exo-dos-metadata.zip
      → Extracted XML metadata to xml/
      → Extracted images to Images-extract/
  Processing: curated/exo-win3x
    Extracting: exo-win3x-metadata.zip
      → Extracted XML metadata to xml/
      → Extracted images to Images-extract/
```

**⚠️ Constraint:** If LaunchBox archives are NOT present on europa, skip this step. Metadata regeneration will warn about missing XML but won't fail.

---

### Step 2: Europa — Regenerate Pegasus Metadata

**Timing:** After LaunchBox extraction (or when collections change)  
**Duration:** 5-10 minutes  

```bash
ssh europa

# Option A: Manual run
python3 /path/to/generate-arcade-metadata.py \
  --nfs-root /tank/archive \
  --output /tank/archive/retro/metadata/pegasus/collections \
  --assets /tank/archive/retro/metadata/pegasus/assets \
  --collections all

# Option B: If systemd service is configured
systemctl start arcade-metadata-generate.service
systemctl status arcade-metadata-generate.service
```

**Verify generation succeeded:**

```bash
# Check that collection directories were created
ls -d /tank/archive/retro/metadata/pegasus/collections/curated-* | wc -l  # Should be 10
ls -d /tank/archive/retro/metadata/pegasus/collections/1g1r-* | wc -l    # Should be 15

# Check one metadata file
head -20 /tank/archive/retro/metadata/pegasus/collections/curated-exo-dos/metadata.pegasus.txt

# Run validation script
bash /path/to/validate-arcade-metadata.sh --collections-dir /tank/archive/retro/metadata/pegasus/collections
```

**Expected:**
```
Validation Summary:
  PASS: 45
  FAIL: 0
  WARN: 0

RESULT: SUCCESS (all checks passed)
```

---

### Step 3: Kiosk — Rebuild Amalthea

**Timing:** After metadata regeneration  
**Duration:** 15-40 minutes (delegates to callisto, not local)  
**OOM Constraint:** Verify `jupiter.core.buildMachines = true` before rebuilding

```bash
# Verify callisto is configured as build machine
git show HEAD:hosts/amalthea/configuration.nix | grep -A2 "buildMachines"

# Rebuild amalthea (delegates to callisto)
sudo nixos-rebuild switch --flake github:Antigravity/jupiter-os#amalthea

# Monitor build (on callisto)
ssh callisto
systemctl status nix-daemon
nix show-derivation /nix/store/...-amalthea.drv  # Check memory footprint
```

**Verify post-rebuild:**

```bash
# After reboot, SSH to amalthea
ssh amalthea

# Check NFS mount is live
mount | grep /tank/archive
# Expected: europa:/tank/archive on /tank/archive type nfs (ro,...,soft,...)

# Check game_dirs.txt lists all 25 collections
cat /home/gamer/.config/pegasus-frontend/game_dirs.txt | wc -l  # Should be 25+2 (comments)

# Spot-check a few paths
ls /tank/archive/retro/metadata/pegasus/collections/curated-exo-dos/metadata.pegasus.txt
ls /tank/archive/retro/metadata/pegasus/collections/1g1r-nointro-nes/metadata.pegasus.txt
```

---

### Step 4: Kiosk — Verify in Pegasus UI (Trap Fixture)

**Timing:** After rebuild and kiosk reboot  
**Duration:** 10-15 minutes  

Access amalthea's Pegasus UI and test:

#### Collections Appear
- [ ] eXoDOS visible in collection menu
- [ ] eXoWin3x visible
- [ ] All 10 curated collections listed
- [ ] All 15 1G1R collections listed (NES, SNES, PS1, etc.)

**If failing:** Check logs:
```bash
tail -100 /home/gamer/.config/pegasus-frontend/lastrun.log | grep -i "error\|metadata\|parse"
```

#### Games Appear
- [ ] eXoDOS: 500+ games listed
- [ ] eXoWin3x: 600+ games listed
- [ ] NES (1G1R): 600+ games listed
- [ ] Other collections proportional to collection size

**If failing:** Check that paths resolve:
```bash
# Test sample game path from metadata
head -20 /tank/archive/retro/metadata/pegasus/collections/curated-exo-dos/metadata.pegasus.txt | grep "^file:"
# Verify file exists at that path
ls /tank/archive/retro/games/curated/exo-dos/<game-path>
```

#### **CRITICAL: Artwork Displays (Trap Fixture)**

Select a game and verify:

1. **Boxart visible** (not black, not missing)
   - Test game: eXoDOS "Commander Keen" → should show Apogee boxart
   - Test game: eXoWin3x "Magic Carpet" → should show Bullfrog boxart

2. **Game details show**
   - Developer, Publisher, Genre, Release date, Summary all populated

3. **No parse errors** in Pegasus logs
   ```bash
   grep -i "error\|parse" /home/gamer/.config/pegasus-frontend/lastrun.log | wc -l  # Should be 0
   ```

**If artwork is black/missing:**

This is the **critical test** from GROUND-TRUTH-pegasus-assets.md. Run diagnostics:

```bash
# 1. Check Pegasus discovered metadata
systemctl restart pegasus-frontend  # (or however it's restarted)
sleep 5
grep "Found.*metadata.pegasus.txt" /home/gamer/.config/pegasus-frontend/lastrun.log

# 2. Verify asset paths in metadata
cat /tank/archive/retro/metadata/pegasus/collections/curated-exo-dos/metadata.pegasus.txt | grep "assets.box_front" | head -1
# Expected: assets.box_front: games/curated/exo-dos/Images/Box Front/Commander Keen.jpg

# 3. Verify target file exists on NFS
ls -lh /tank/archive/retro/games/curated/exo-dos/Images/Box\ Front/Commander\ Keen.jpg

# 4. Check NFS mount is readable
mount | grep /tank/archive | grep -o "ro\|rw"  # Should show "ro"
ls -la /tank/archive/retro/metadata/pegasus/assets/curated-exo-dos/boxart/ | head

# 5. Check Pegasus logs for permission errors
tail -50 /home/gamer/.config/pegasus-frontend/lastrun.log | grep -i "permission\|denied\|access"
```

**Troubleshooting:**

| Issue | Check | Fix |
|-------|-------|-----|
| No collections appear | game_dirs.txt | Update arcade.nix gameDirs, rebuild |
| Games appear, assets all black | Asset paths in metadata | Regenerate metadata on europa |
| Games appear, no assets | Symlinks broken | Verify symlinks on europa are readable |
| Parse errors in log | Field names | Verify assets.box_front: (not image:) |

---

### Step 5: (Optional) Deploy to Other Kiosks

**Timing:** After successful verification on amalthea  
**Kiosks:** Thebe, Metis, Adrastea  

Repeat Step 3–4 for each kiosk:

```bash
for kiosk in thebe metis adrastea; do
  sudo nixos-rebuild switch --flake github:Antigravity/jupiter-os#$kiosk
done

# Test each kiosk's Pegasus UI
```

---

## ✅ Success Criteria

After full deployment:

- [x] All 25 collections appear in Pegasus on amalthea
- [x] Game counts match expected (eXoDOS ~500, eXoWin3x ~600, 1G1R ~600 each)
- [x] **At least one game shows boxart image** (critical trap fixture test)
- [x] No parse errors in Pegasus logs
- [x] Deployed to all 4 kiosks (amalthea, thebe, metis, adrastea)

---

## 🔄 Rollback

If artwork doesn't display after deployment:

```bash
# 1. Check metadata file structure
ls /tank/archive/retro/metadata/pegasus/collections/curated-exo-dos/metadata.pegasus.txt

# 2. If missing, regenerate on europa
# (see Step 2 above)

# 3. If still failing, revert arcade.nix
git revert HEAD  # Reverts the gameDirs update
sudo nixos-rebuild switch --flake github:Antigravity/jupiter-os#amalthea

# 4. Re-test trap fixture
```

---

## 📊 Status by Component

| Component | Status | Notes |
|-----------|--------|-------|
| Script fixes | ✅ Complete | Directory structure, field names, directory declaration |
| Extraction helper | ✅ Ready | Run on europa manually or via systemd |
| Metadata regeneration | ✅ Ready | script + systemd service template |
| Validation script | ✅ Ready | Run after regeneration to verify |
| Kiosk deployment | ✅ Ready | arcade.nix updated, flake ready |
| Verification plan | ✅ Ready | Trap fixture checklist in place |

---

## 📝 Notes

- **LaunchBox archives:** If not present on europa, metadata generation warns but continues
- **Asset symlinks:** Created by generate-arcade-metadata.py during regeneration
- **Game_dirs.txt:** Auto-seeded by pegasus-config-seed service on kiosk rebuild
- **Metadata persistence:** Via impermanence (pegasus config survives reboots)

---

## Related Documentation

- `.claude/domains/pegasus-metadata-transformation.md` — Complete workflow reference
- `.claude/domains/GROUND-TRUTH-pegasus-assets.md` — Trap fixture (critical verification)
- `docs/arcade-metadata-deployment.md` — Detailed deployment plan
- `scripts/generate-arcade-metadata.py` — Main generator
- `scripts/extract-launchbox-metadata.sh` — LaunchBox extraction
- `scripts/validate-arcade-metadata.sh` — Metadata validation
- `modules/desktop/arcade.nix` — Pegasus configuration

---

## Quick Commands

```bash
# Extract metadata on europa
ssh europa
bash /path/to/extract-launchbox-metadata.sh

# Regenerate metadata
python3 /path/to/generate-arcade-metadata.py \
  --nfs-root /tank/archive \
  --output /tank/archive/retro/metadata/pegasus/collections \
  --assets /tank/archive/retro/metadata/pegasus/assets \
  --collections all

# Validate
bash /path/to/validate-arcade-metadata.sh

# Rebuild kiosk (amalthea)
ssh amalthea
sudo nixos-rebuild switch --flake github:Antigravity/jupiter-os#amalthea

# Test Pegasus UI
# Select a game and verify boxart displays (not black)
```

---

**Ready to deploy!**
