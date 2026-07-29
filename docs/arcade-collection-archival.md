# Game Collection Archival Guide

This document outlines the process for archiving full game collections to the jupiter-os arcade system.

## Current Status

### Already on europa (awaiting consolidation):
- **eXoDOS**: 642 GB at `/mnt/europa/games/eXoDOS`
- **eXoWin3x**: 352 GB at `/mnt/europa/games/eXoWin3x`

### Target location (ZFS-backed):
- `/tank/archive/retro/games/curated/exo-dos/` (eXoDOS)
- `/tank/archive/retro/games/curated/exo-win3x/` (eXoWin3x)
- `/tank/archive/retro/games/curated/exo-win9x/` (eXoWin9x - to be downloaded)

## Consolidation Process

### For Existing Collections (eXoDOS, eXoWin3x)

Run on europa:
```bash
ssh root@10.1.1.2 bash /root/consolidate-collections.sh
```

This script:
1. Copies collections from `/mnt/europa/games` to `/tank/archive/retro/games/curated/` (europa pool is read-only)
2. Verifies LaunchBox XML metadata is intact
3. Generates Pegasus collection files
4. Logs all operations to `/var/log/consolidate-collections.log`

**Expected time**: 2-4 hours (copying ~1 TB of data)
**Disk impact**: ~1 TB additional space needed on `/tank/archive/retro/games/curated/`

After consolidation:
```bash
# Verify collections are accessible
ssh root@10.1.1.2 "du -sh /tank/archive/retro/games/curated/exo-*"

# Check metadata generation
ssh root@10.1.1.2 "ls -lh /tank/archive/retro/metadata/pegasus/collections/curated-*.txt"
```

### For New Collections (eXoWin9x, etc.)

#### Step 1: Download the torrent
- Visit: https://www.retro-exo.com/win9x.html
- Download torrent for eXoWin9x Vol. 1 (~262 GB compressed)
- Seed/download to get the `.7z` archive

#### Step 2: Run setup script
```bash
scp /path/to/eXoWin9x_Vol1_v*.7z root@10.1.1.2:/tmp/

ssh root@10.1.1.2 bash /root/jupiter-os/scripts/setup-exowin9x.sh /tmp/eXoWin9x_Vol1_v*.7z
```

**Expected time**: 30-60 minutes (extraction + organization)
**Disk space needed**: ~400 GB free on `/tank/archive/retro/games/curated`

## Directory Structure

Each collection follows this layout:

### LaunchBox-based collections (eXoDOS, eXoWin3x, C64 Dreams, etc.):
```
/tank/archive/retro/games/curated/<collection>/
├── Games/                           # Actual game files
├── Data/
│   └── Platforms/
│       └── <Platform>.xml          # LaunchBox metadata (required!)
├── Core/                           # Emulator configs
├── Images/                         # Screenshots, artwork
├── Manuals/                        # PDF manuals
└── Metadata/                       # Additional metadata
```

### Emulator-based collections (eXoWin9x with VHD, etc.):
```
/tank/archive/retro/games/curated/exo-win9x/
├── Games/                          # 664 game folders
├── DOSBox-X/                       # Emulator configs
├── PCem/                           # Emulator configs
├── VHD/                            # Virtual hard drives
├── Glide/                          # 3dfx Glide wrappers
├── _Windows/                       # Shared components
└── Extras/                         # Manuals, soundtracks, patches
```

## Integration with Pegasus

After consolidation/setup, the metadata generator creates Pegasus collection files:

```
/tank/archive/retro/metadata/pegasus/collections/
├── curated-exo-dos.txt            # Generated from Data/Platforms/MS-DOS.xml
├── curated-exo-win3x.txt          # Generated from Data/Platforms/Windows 3x.xml
├── curated-exo-win9x.txt          # Generated from directory scan
└── ...
```

These files are read by Pegasus frontend on the kiosks and make the games available for launching.

## Troubleshooting

### Script fails with "Permission denied"
- Ensure you're running as root on europa
- Check SSH key access: `ssh root@10.1.1.2 "whoami"`

### Collections not appearing in Pegasus on kiosk
1. Verify metadata was generated: `ssh root@10.1.1.2 "ls -l /tank/archive/retro/metadata/pegasus/collections/"`
2. Check NFS mount on kiosk: `mount | grep tank/archive`
3. Verify Pegasus config: `cat ~/.config/pegasus-frontend/game_dirs.txt` (on kiosk)
4. Check logs: `journalctl -u pegasus-rom-launch -n 50`

### Low disk space on /tank/archive
- Check current usage: `ssh root@10.1.1.2 "zfs list -h tank/archive"`
- Consolidation uses hard-links (no extra space), but verify source is not needed
- After confirmation, can remove `/mnt/europa/games/eXoDOS` etc. to free space

## Collection Information

| Collection | Source | Size | Status | Platform | Emulator |
|-----------|--------|------|--------|----------|----------|
| eXoDOS | LaunchBox | 642 GB | ✅ On NAS | DOS | DOSBox-staging |
| eXoWin3x | LaunchBox | 352 GB | ✅ On NAS | Windows 3.x | DOSBox-X |
| eXoWin9x | Retro-eXo | ~400 GB | ⏳ To download | Windows 95/98 | PCem/DOSBox-X |
| C64 Dreams | LaunchBox | ~50 GB | ⏳ To archive | Commodore 64 | VICE |
| OneLoad64 | Directory | ~30 GB | ⏳ To archive | Commodore 64 | VICE |
| eXoIF | Directory | ~10 GB | ⏳ To archive | Interactive Fiction | Gargoyle |
| eXoDemoScene | Directory | ~20 GB | ⏳ To archive | Demo | DOSBox |
| eXoAppleIIGS | Directory | ~50 GB | ⏳ To archive | Apple IIGS | GSplus |
| eXoScummVM | Directory | ~30 GB | ⏳ To archive | Adventure | ScummVM |
| Mega-AGS | Directory | ~60 GB | ⏳ To archive | Amiga | FS-UAE |

## Related Issues

- [Issue #19](https://github.com/belikh/jupiter-os/issues/19) - eXoWin9x archival (Windows 95/98)
- [Issue #31](https://github.com/belikh/jupiter-os/issues/31) - eXoDOS consolidation
- [Issue #32](https://github.com/belikh/jupiter-os/issues/32) - eXoWin3x consolidation
- [Issue #30](https://github.com/belikh/jupiter-os/issues/30) - Architecture & integration
