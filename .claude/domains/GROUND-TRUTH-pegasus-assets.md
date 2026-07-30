---
title: "Pegasus Metadata Transformation - Asset Path Trap"
description: "Trap fixture testing correct asset path resolution in Pegasus .pegasus.txt files"
scoring:
  - total: 2 points
  - partial_credit: 0 (binary: assets work or don't)
  - perfect: Both metadata validates AND assets display in UI
---

# Task

You're given a LaunchBox collection with embedded image paths. Convert it to Pegasus format such that:
1. Games appear in Pegasus UI
2. **Assets (boxart, screenshots) actually display** — not blank/black/missing

This is the critical test: metadata syntax alone isn't enough. The paths must resolve correctly so Pegasus finds real image files.

## Ground Truth

**Input:** eXoWin9x collection (games extracted to `/tank/archive/retro/games/curated/exo-win9x/`, images at `Images-extract/`)

**Output:** 
- `.pegasus.txt` metadata file at `/tank/archive/retro/metadata/pegasus/collections/exo-win9x/metadata.pegasus.txt`
- Asset symlinks organized at `/tank/archive/retro/metadata/pegasus/assets/curated-exo-win9x/`

**Success criteria:**
1. ✓ Pegasus discovers metadata file (log: "Found .../metadata.pegasus.txt")
2. ✓ Games list appears in UI (count > 0)
3. ✓ **At least one game shows actual boxart image** (not black/blank)
   - Indicates: asset format recognized + paths resolve + files readable

**Failure modes (trap):**
- **"All black"** images → paths wrong or files unreadable
- **No assets at all** → field names wrong (`image:` instead of `assets.box_front:`)
- **Parse error** → unrecognized field or syntax issue

## The Trap

Tempting (but WRONG) approaches that will fail:

1. **Use `image:` field name** — Pegasus doesn't recognize it
   - ❌ Pegasus log: "Unrecognized game property 'image'"
   - ✓ Use: `assets.box_front:`

2. **Hardcode absolute Windows paths from LaunchBox XML** — won't work on Linux
   - ❌ Pegasus log: file not found
   - ✓ Use: Relative paths + `directory:` declaration

3. **Point `game_dirs.txt` to parent directory** — Pegasus looks for metadata files in that exact directory
   - ❌ Pegasus log: "No metadata files found"
   - ✓ Point to subdirectories: `/tank/archive/retro/metadata/pegasus/collections/exo-win9x/`

4. **Forget `directory:` declaration** — relative paths fail silently
   - ❌ Pegasus UI: games appear but no assets, or files can't be resolved
   - ✓ Include: `directory: /tank/archive/retro` in metadata header

5. **Create asset symlinks with wrong extensions** — `.jpg` symlink to `.png` file
   - ❌ Pegasus UI: all black images
   - ✓ Verify: symlink target and declared path have matching extensions

## Verification Steps

Run these to verify the fix works:

```bash
# 1. Check metadata file exists and is valid
head -20 /tank/archive/retro/metadata/pegasus/collections/exo-win9x/metadata.pegasus.txt
# Should show: collection, shortname, directory, game, file, assets.box_front

# 2. Check Pegasus discovered it (fresh log)
systemctl restart jupiter-arcade && sleep 5
grep "Metafiles.*Found.*metadata.pegasus.txt" /home/gamer/.config/pegasus-frontend/lastrun.log
# Should appear (not "No metadata files found")

# 3. Test asset path resolution
cat /tank/archive/retro/metadata/pegasus/collections/exo-win9x/metadata.pegasus.txt | grep "assets.box_front" | head -1
# Example output: assets.box_front: /tank/archive/retro/metadata/pegasus/assets/curated-exo-win9x/boxart/Game Name.jpg

# 4. Verify target file exists
readlink -f /tank/archive/retro/metadata/pegasus/assets/curated-exo-win9x/boxart/20\ Squares.jpg
ls -lh /tank/archive/retro/games/curated/exo-win9x/Images-extract/Images/Windows\ 9x/Box\ -\ Front/20\ Squares-01.jpg
# Both should exist and be readable

# 5. Check Pegasus UI
# Should show eXoWin9x collection with 600+ games
# At least one game (e.g., "20 Squares") shows boxart image (not black)
```

## Scoring

- **2 points (Perfect):** Games appear in UI AND at least one asset displays correctly
- **1 point (Partial):** Games appear but assets are missing or black (wrong paths or format)
- **0 points (Failed):** No games appear or metadata doesn't parse (syntax error, wrong field names)

## Why This Trap Matters

This is the **one place the workflow fails in practice**: all the metadata can be syntactically correct, games discover perfectly, but if asset paths don't resolve or field names are wrong, users see "no artwork". The trap forces testing end-to-end, not just "metadata parses."

