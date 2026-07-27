# Architecture: Pegasus + On-Demand ROM Loading with Bubble Tea TUI

## Goal
A simple, maintainable arcade setup where:
- **Pegasus shows all games** from curated collections + 1G1R mirrors
- **Curated games** (eXoDOS, eXoWin3x, hand-picked ROMs) launch from NFS
- **1G1R games** (No-Intro, Redump) download from mirrors on first play
- **Bubble Tea TUI** shows download/extract progress with cancel support
- **Zero manual maintenance** — cached games available instantly on next play

---

## Architecture

### 1. Collection Storage

**On NAS (`/tank/archive/retro/games` via NFS):**
```
/tank/archive/retro/games/
├── curated/
│   ├── c64-dreams/
│   │   ├── Boulder Dash.d64
│   │   ├── Jumpman.d64
│   │   └── ...
│   ├── exo-dos/
│   │   ├── Commander Keen/keen1.zip
│   │   ├── Duke Nukem 3D/duke3d.zip
│   │   └── ...
│   ├── exo-win3x/
│   │   ├── Magic Carpet/mcarpet.zip
│   │   ├── Ultima Underworld/ultima.zip
│   │   └── ...
│   ├── exo-if/
│   ├── exo-demos/
│   ├── exo-appleiigs/
│   ├── oneload64/
│   └── [other curated collections]
│
├── 1g1r/
│   ├── nointro-nes.dat                 # DAT metadata (not full ROMs)
│   ├── nointro-snes.dat
│   ├── redump-ps1.dat
│   └── ...
│
└── pegasus/
    ├── collections/
    │   ├── curated-c64-dreams.txt
    │   ├── curated-exo-dos.txt
    │   ├── curated-exo-win3x.txt
    │   ├── 1g1r-nointro-nes.txt
    │   ├── 1g1r-redump-ps1.txt
    │   └── ...
    └── assets/
        ├── boxart/
        ├── screenshots/
        └── logos/
```

**Local Kiosk Caches:**
```
/tmp/pegasus-cache/                    # Ephemeral (cleared on reboot)
├── keen1/                             # Extracted eXoDOS
├── mcarpet/                           # Extracted eXoWin3x
└── (small files, fast extraction)

/var/cache/pegasus-roms/               # Persistent (survives reboot)
├── Super Mario Bros.nes               # Downloaded from mirror
├── Crash Bandicoot.chd                # Downloaded from mirror
└── (large ROMs cached from mirrors)
```

### 2. Game Launcher Script

```bash
#!/bin/bash
# /usr/local/bin/pegasus-rom-launch

rom_path="$1"  # e.g., "curated/exo-dos/keen1.zip" or "1g1r-nes/Super Mario Bros.nes"
nfs_mount="/tank/archive/retro/games"
tmp_cache="/tmp/pegasus-cache"
persistent_cache="/var/cache/pegasus-roms"

game_name=$(basename "$rom_path" | sed 's/\.[^.]*$//')

# 1. Check both caches
if [ -f "$tmp_cache/$game_name" ] || [ -f "$persistent_cache/$game_name" ]; then
  exec emulator "$tmp_cache/$game_name" 2>/dev/null || exec emulator "$persistent_cache/$game_name"
fi

if [ -d "$tmp_cache/$game_name" ] || [ -d "$persistent_cache/$game_name" ]; then
  exec emulator "$tmp_cache/$game_name" 2>/dev/null || exec emulator "$persistent_cache/$game_name"
fi

# 2. Check if game exists locally on NFS
if [ -f "$nfs_mount/$rom_path" ] || [ -d "$nfs_mount/$rom_path" ]; then
  # Curated collection (local)
  if [[ "$rom_path" == *.zip ]]; then
    # Archive → extract to /tmp
    cache_dir="$tmp_cache"
    operation="extract"
  else
    # Direct ROM → launch immediately from NFS
    exec emulator "$nfs_mount/$rom_path"
  fi
else
  # 1G1R collection (fetch from mirror)
  cache_dir="$persistent_cache"
  operation="download"
fi

mkdir -p "$cache_dir"

# 3. Show TUI during download/extract
bubbletea-game-loader \
  --src "$rom_path" \
  --dst "$cache_dir/$game_name" \
  --operation "$operation" \
  --nfs-mount "$nfs_mount" \
  --title "$(basename "$rom_path")"

# 4. Launch emulator
exec emulator "$cache_dir/$game_name"
```

### 3. Bubble Tea Game Loader

A single Go binary that handles:
- **Extract**: Unzip curated collections to `/tmp` with progress bar
- **Download**: Fetch from Myrient mirror to persistent cache with speed/ETA
- **Cancel**: Cleanup partial files on 'q' key

```go
// bubbletea-game-loader/main.go
// ~250 lines, handles archive extraction and HTTP downloads with progress
// Theme: Catppuccin Mocha
// Display:
//   🎮 Loading: Commander Keen
//   ████████████░░░░░░░░░░░░░░░░░░░░░░ 35%
//   Downloading  •  12.5 MB/s  •  ETA: 8s
//   Press 'q' to cancel
```

Features:
- Real-time progress (% complete)
- Speed + ETA (for downloads)
- Mirror retry on failure
- Cancel support (cleans up `/tmp` or partial downloads)
- Catppuccin Mocha theme (matches kiosk aesthetic)

### 4. Pegasus Configuration

**NixOS module** (`modules/desktop/tcxwave-kiosk.nix`):
```nix
fileSystems."/tank/archive" = {
  device = "europa:/tank/archive";
  fsType = "nfs";
  options = [ "ro" "soft" "intr" ];
};

xdg.configFile."pegasus-frontend/settings.txt".text = ''
  collections.directory=/tank/archive/retro/metadata/pegasus/collections
  assets.directory=/tank/archive/retro/metadata/pegasus/assets
  launcher.script=/usr/local/bin/pegasus-rom-launch
'';

environment.systemPackages = with pkgs; [
  pegasus-frontend
  (callPackage ./bubbletea-game-loader { })
  retroarch
  dosbox
  # other emulators...
];
```

### 5. Pegasus Metadata

Pegasus collection files point to either NFS paths (curated) or DAT-derived entries (1G1R):

**curated-exo-dos.txt:**
```
title=eXo-DOS (Curated)
path=/tank/archive/retro/games/curated/exo-dos
extension=.zip
launch=pegasus://launch/rom-cache/{file.name}
```

**1g1r-nointro-nes.txt:**
```
title=NES (1G1R)
path=generated-from-dat
# Games sourced from Myrient on first play
launch=pegasus://launch/rom-cache/{file.name}
```

Metadata generator (simple script/binary):
- Reads curated directory structure → Pegasus collection files
- Reads 1G1R DAT files → Pegasus entries (title, hash, region, year)
- Outputs complete collection YAML/TXT for Pegasus

---

## Implementation Plan

### Week 1: Core Setup
- [ ] NFS mount `/tank/archive/retro/games` on all kiosks
- [ ] Curate 50-100 games per system (test in RetroArch)
- [ ] Create Pegasus collection directory structure

### Week 2: TUI + Launcher
- [ ] Build `bubbletea-game-loader` (extract + download modes)
- [ ] Write `pegasus-rom-launch` bash wrapper
- [ ] Test on one kiosk with mix of curated + mirror games

### Week 3: Deployment
- [ ] Add NixOS module to kiosk config
- [ ] Deploy to all 4 kiosks
- [ ] Verify Pegasus shows all games correctly

### Week 4: Polish (Optional)
- [ ] Mirror failover logic (fallback mirrors if Myrient down)
- [ ] LRU eviction for persistent cache (if `/var/cache` fills)
- [ ] Prefetch popular games daily (from play logs)

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **NFS mount** | Games always available; no complex sync logic |
| **Two-tier cache** | `/tmp` for fast extraction, persistent for downloads |
| **Bubble Tea TUI** | Terminal-native, themeable, handles both extract/download |
| **No API server** | Direct NFS + mirror fetches; launcher orchestrates |
| **No DAT pipeline** | Curated collections hand-managed; 1G1R DATs versioned in repo |
| **Myrient as primary mirror** | Stable, comprehensive, covers No-Intro + Redump |

---

## Runtime Flow

### Curated ROM (eXoDOS zip on first play):
```
User selects "Commander Keen"
    ↓
Launch script finds keen1.zip on NFS
    ↓
Check /tmp cache → miss
    ↓
TUI appears:
  🎮 Loading: Commander Keen
  ████████░░░░░░░░░░░ 40%
  Extracting
    ↓
Extract to /tmp/pegasus-cache/keen1/
    ↓
Launch DOSBox with /tmp/pegasus-cache/keen1/
    ↓
Next play: Cache HIT → instant launch (no TUI)
```

### 1G1R ROM (NES from mirror on first play):
```
User selects "Super Mario Bros"
    ↓
Launch script doesn't find on NFS
    ↓
Check persistent cache → miss
    ↓
TUI appears:
  🎮 Loading: Super Mario Bros
  ████████████░░░░░░░░░ 58%
  Downloading  •  15.2 MB/s  •  ETA: 3s
    ↓
Download from Myrient to /var/cache/pegasus-roms/Super Mario Bros.nes
    ↓
Launch RetroArch with /var/cache/pegasus-roms/Super Mario Bros.nes
    ↓
Next play: Cache HIT → instant launch (no TUI)
```

### Already Cached:
```
User selects any cached game
    ↓
Check cache → HIT
    ↓
Launch instantly (no TUI, <1s)
```

---

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Mirror downtime | Hardcode 2-3 fallback mirrors (Myrient, archive.org, etc.) |
| NFS network latency | Kiosk kernel caches recently-played games |
| Cache fills up | LRU eviction at 80% threshold; cleanup script |
| DAT metadata drift | DAT files versioned in repo; regenerate monthly |
| Emulator compatibility | Per-system core mapping; test curated games once |

---

## Success Criteria
1. ✅ Pegasus shows all curated + 1G1R games
2. ✅ First play of cached game → TUI shows progress → launches
3. ✅ Second play of same game → instant (< 1 second)
4. ✅ Works on all 4 TCxWave kiosks
5. ✅ No manual maintenance after deployment

---

## Related Issues
- #19, #20, #21, #22, #23, #24, #25, #26, #27, #28, #29 (prior architecture, collection curation)
- This issue: **Final implementation plan** (simplified, NFS-based, Bubble Tea TUI)
