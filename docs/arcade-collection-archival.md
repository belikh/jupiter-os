# Game Collection Archival Guide

> **⚠️ STALE (2026-08): the procedures below describe the RETIRED issue-30
> stack and must not be followed.** `consolidate-collections.sh` and
> `setup-exowin9x.sh` now live in `scripts/deprecated/` (the former is
> destructive if re-run — it zfs-destroys staging datasets), the
> `jupiter.services.arcadeCollectionDownloader` option and
> `/etc/download-arcade-torrent.sh` do not exist in any module, and
> `pegasus-rom-launch` was never a Pegasus setting. The live acquisition +
> archival pipeline is:
>
> - **Console ROM sets** — `modules/services/rom-acquire.nix`
>   (`jupiter-rom-acquire` aria2 oneshot → `jupiter-rom-verify` igir DAT
>   verify/promote) + `modules/services/rom-scraper.nix` (Skyscraper →
> Pegasus metadata). See `docs/adr/0001-bulk-staged-rom-acquisition.md`.
> - **Large curated collections (eXo & friends)** — stage the data under
>   `/tank/archive/retro/games/curated/<name>/` (own ZFS dataset per
>   collection, `modules/storage/zfs-nas.nix`), then wire it kiosk-side the
>   way `modules/desktop/exodos.nix` does (per-collection RO NFS mount +
>   metadata generator + launcher). There is no generic downloader service;
>   fetching a collection torrent is a one-time manual step on europa.
>
> The directory-layout notes and the collection table below remain accurate
> reference material.

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

This script uses **ZFS send/recv** to efficiently consolidate collections:
1. Creates ZFS datasets from source collections via tar pipe
2. Receives into `/tank/archive/retro/games/curated/` datasets
3. Verifies LaunchBox XML metadata is intact
4. Generates Pegasus collection files
5. Logs all operations to `/var/log/consolidate-collections.log`

**Expected time**: 30-60 minutes (ZFS is very efficient)
**Disk impact**: ~1 TB on `/tank/archive` (deduplication may help)
**Individual games**: Stored as-is, launched on-demand at runtime

**Benefits of ZFS send/recv:**
- Atomic snapshots
- Efficient stream 
- Preserves metadata and permissions
- Can resume on network interruption
- No per-game extraction overhead

After consolidation:
```bash
# Verify collections are accessible
ssh root@10.1.1.2 "du -sh /tank/archive/retro/games/curated/exo-*"

# Check metadata generation
ssh root@10.1.1.2 "ls -lh /tank/archive/retro/metadata/pegasus/collections/curated-*.txt"
```

### For New Collections (eXoWin9x, etc.) - Background Download

Europa can run Transmission daemon to seed/download large collections in the background:

#### Step 1: Enable the downloader service
```bash
# On europa's configuration (hosts/europa/configuration.nix)
jupiter.services.arcadeCollectionDownloader = {
  enable = true;
  exowin9x.enable = true;
  downloadDir = "/tank/archive/retro/downloads";
};
```

Or enable via nixos-rebuild:
```bash
ssh root@10.1.1.2 "cd /root/jupiter-os && nixos-rebuild switch --flake .#europa"
```

#### Step 2: Provide torrent file to transmission
The torrent contains the eXoWin9x collection (~262 GB compressed or pre-extracted):

```bash
# Download .torrent file from: https://www.retro-exo.com/win9x.html
scp eXoWin9x_Vol1_v*.torrent root@10.1.1.2:/tmp/

# Start download via transmission
ssh root@10.1.1.2 /etc/download-arcade-torrent.sh /tmp/eXoWin9x_Vol1_v*.torrent
```

#### Step 3: Monitor progress
```bash
ssh root@10.1.1.2 "tail -f /var/log/transmission.log"
# Or check folder: ssh root@10.1.1.2 "ls -lh /tank/archive/retro/downloads/"
```

#### Step 4: Consolidate when complete
Once transmission finishes downloading:
```bash
# If torrent contains .7z file:
ssh root@10.1.1.2 bash /root/jupiter-os/scripts/setup-exowin9x.sh /tank/archive/retro/downloads/eXoWin9x_Vol1_v*.7z

# If torrent contains extracted collection:
ssh root@10.1.1.2 bash /root/consolidate-collections.sh  # (same as eXoDOS/Win3x)
```

**Expected time**: 
- Download: Varies by connection speed and torrent availability
- Consolidation: 30-60 minutes (ZFS send/recv)

**Disk space needed**: ~262 GB for download + buffer for consolidation

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
