# jupiter-os Arcade Architecture (Branch: arcade-pegasus-architecture)

## Overview
This branch implements the jupiterOS Arcade system per GitHub issue #30: **Pegasus frontend with on-demand ROM loading via NFS + Myrient mirrors**, using a Bubble Tea TUI for progress display.

**Key principle:** Kiosks are consumers only. No API server, no timers, no DAT processing on kiosks. Europa NAS serves NFS; kiosks mount + launch.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ EUROPA (10.1.1.2) — NAS/ZFS                                                 │
│   /tank/archive/retro/                                                      │
│   ├── games/                                                                │
│   │   ├── curated/        ← eXoDOS, eXoWin3x, C64 Dreams, OneLoad64, etc.  │
│   │   │   ├── exo-dos/    (ZIPs, LaunchBox XML)                            │
│   │   │   ├── exo-win3x/  (ZIPs, LaunchBox XML)                            │
│   │   │   ├── c64-dreams/ (extracted + LaunchBox)                          │
│   │   │   ├── oneload64/  (.CRT cartridge images)                          │
│   │   │   └── ...                                                        │
│   │   ├── 1g1r/           ← DAT metadata only (No-Intro, Redump, TOSEC)    │
│   │   │   ├── nointro-nes.dat                                              │
│   │   │   ├── nointro-snes.dat                                             │
│   │   │   ├── redump-ps1.dat                                               │
│   │   │   └── ...                                                          │
│   │   └── pegasus/         ← Generated Pegasus collections + assets        │
│   │       ├── collections/  (metadata.pegasus.txt per collection)          │
│   │       └── assets/       (boxart/, screenshots/, logos/)                │
│   └── (served via NFS, read-only, to 10.1.1.0/24)                         │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │ NFS (ro,soft,intr,automount)
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ TCxWave KIOSKS ×4 (amalthea, metis, adrastea, thebe)                        │
│   /tank/archive          ← NFS mount (ro)                                   │
│   /tmp/pegasus-cache/    ← Ephemeral extraction cache (tmpfs, cleared reboot)│
│   /var/cache/pegasus-roms/← Persistent download cache (impermanence)        │
│                                                                             │
│   SERVICES:                                                                 │
│   ├── pegasus-frontend     ← Reads collections from NFS                    │
│   ├── pegasus-rom-launch   ← Dispatcher: cache → NFS extract → Myrient DL      │
│   └── bubbletea-game-loader← Go TUI: extract/download progress + cancel    │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Module Structure

| File | Purpose |
|------|---------|
| `modules/desktop/arcade.nix` | Main arcade module: NFS mount, caches, Pegasus config, packages |
| `modules/desktop/dashboard-gaming.nix` | Gaming modes — **only `dashboard` + `arcade` enabled** |
| `modules/desktop/tcxwave-kiosk.nix` | Kiosk profile — imports arcade, enables arcade mode |
| `modules/storage/nas-nfs.nix` | NFS exports for `/tank/archive/retro` |
| `modules/storage/zfs-nas.nix` | ZFS datasets for `tank/archive/retro/*` |
| `scripts/bubbletea-game-loader/` | Go TUI for extract/download with Catppuccin Mocha theme |
| `scripts/pegasus-rom-launch` | Bash dispatcher: cache → NFS extract → Myrient download |
| `scripts/generate-arcade-metadata.py` | Generates Pegasus collections from NFS sources |

---

## Collections (Curated + 1G1R)

### Curated (NFS-resident, extract on first play)
- **eXoDOS** — 7,200+ DOS games (LaunchBox XML + ZIPs)
- **eXoWin3x** — 1,140+ Win3.x games (LaunchBox XML + ZIPs)
- **C64 Dreams** — 3,500+ C64 games (extracted + LaunchBox)
- **OneLoad64** — 2,000+ C64 .CRT cartridge images
- **eXoScummVM** — 800+ adventure games (ScummVM-ready)
- **eXoAppleIIGS** — Apple IIGS library
- **eXoIF** — Interactive Fiction (text adventures)
- **eXoDemoScene** — PC demoscene productions
- **eXoWin9x** — Win95/98 games (PCem/DOSBox-X)
- **Mega-AGS / AmigaVision** — Amiga WHDLoad sets
- **TOSEC** — Microcomputer preservation sets (Tier 1 systems)

### 1G1R (DAT on NFS, ROMs from Myrient mirrors)
- **No-Intro** — NES, SNES, Genesis, GB/GBC/GBA, N64, DS, etc.
- **Redump** — PS1, PS2, PSP, Saturn, Dreamcast, GC, Wii, Xbox
- **TOSEC** — Optical/disc sets where applicable

---

## Runtime Flow

### Curated Game (e.g., eXoDOS ZIP on NFS)
```
User selects "Commander Keen" in Pegasus
    ↓
pegasus-rom-launch "curated/exo-dos/Commander Keen.zip"
    ↓
Check /tmp/pegasus-cache/Commander Keen/ → MISS
Check /var/cache/pegasus-roms/Commander Keen/ → MISS
    ↓
NFS path exists? YES → curated
    ↓
bubbletea-game-loader --src "curated/exo-dos/Commander Keen.zip" \
                       --dst "/tmp/pegasus-cache/Commander Keen" \
                       --operation extract \
                       --title "Commander Keen"
    ↓
[TUI: 🎮 Loading: Commander Keen ████████░░ 40% Extracting... Press 'q' to cancel]
    ↓
Extract ZIP to /tmp/pegasus-cache/Commander Keen/ (via sudo exo-extract-helper)
    ↓
Launch dosbox-staging with /tmp/pegasus-cache/Commander Keen/dosbox.conf
    ↓
Next play: Cache HIT → instant launch (no TUI)
```

### 1G1R Game (e.g., NES from Myrient)
```
User selects "Super Mario Bros." in Pegasus
    ↓
pegasus-rom-launch "1g1r-nointro-nes/Super Mario Bros.nes"
    ↓
Check /tmp/pegasus-cache/... → MISS
Check /var/cache/pegasus-roms/Super Mario Bros.nes → MISS
    ↓
NFS path exists? NO → 1G1R
    ↓
bubbletea-game-loader --src "1g1r-nointro-nes/Super Mario Bros.nes" \
                       --dst "/var/cache/pegasus-roms/Super Mario Bros.nes" \
                       --operation download \
                       --title "Super Mario Bros."
    ↓
[TUI: 🎮 Loading: Super Mario Bros. ████████████░░ 58% Downloading • 15.2 MB/s • ETA: 3s]
    ↓
Download from Myrient mirror (https://myrient.erista.me/files/No-Intro/NES/...)
    ↓
Launch retroarch with /var/cache/pegasus-roms/Super Mario Bros.nes
    ↓
Next play: Cache HIT → instant launch (no TUI)
```

---

## Key Scripts

### `scripts/pegasus-rom-launch` (Bash Dispatcher)
- Input: `collection/relative/path` (e.g., `curated/exo-dos/keen1.zip` or `1g1r-nointro-nes/mario.nes`)
- Checks: `/tmp/pegasus-cache/` → `/var/cache/pegasus-roms/` → NFS
- Curated ZIP → extract to `/tmp/pegasus-cache/` via `bubbletea-game-loader --operation extract`
- 1G1R → download to `/var/cache/pegasus-roms/` via `bubbletea-game-loader --operation download`
- Execs emulator with cache path

### `scripts/bubbletea-game-loader` (Go TUI)
- Single binary: handles both extract (unzip) and download (HTTP with resume)
- Catppuccin Mocha theme
- Real-time progress bar, speed, ETA
- 'q' key cancels → cleans up partial files
- Mirror fallback (tries mirrors in order)

### `scripts/generate-arcade-metadata.py`
- Runs on europa (or at build time) to generate Pegasus collections
- Inputs:
  - LaunchBox XML (eXoDOS, eXoWin3x, C64 Dreams, etc.)
  - DAT files (No-Intro, Redump) → 1G1R entries with Myrient URLs
  - Directory scans (OneLoad64, TOSEC)
- Output: `/tank/archive/retro/metadata/pegasus/collections/*.txt`
- Assets symlinked from collection sources

---

## Dashboard-Gaming Integration

`modules/desktop/dashboard-gaming.nix` modeSpecs now has **only two modes**:
1. `dashboard` — Cage + Chromium (Home Assistant)
2. `arcade` — gamescope + pegasus-frontend

Removed: `steam`, `heroic`, `lutris`, `exodos` (replaced by `arcade`)

Session switching via HA `select` entity (group: "session").

---

## Deployment Checklist

- [ ] Europa: ZFS datasets created (`tank/archive/retro/*`)
- [ ] Europa: NFS exports configured (`/tank/archive/retro`)
- [ ] Europa: Curated collections populated on disk
- [ ] Europa: 1G1R DAT files placed in `/tank/archive/retro/games/1g1r/`
- [ ] Europa: Run `generate-arcade-metadata.py` → Pegasus collections on NFS
- [ ] Kiosks: `make check` passes
- [ ] Kiosks: Deploy arcade mode (`jupiter.dashboardGaming.modes.arcade.enable = true`)
- [ ] Kiosks: Verify Pegasus shows all collections
- [ ] Test: First play curated game → TUI extract → launch
- [ ] Test: First play 1G1R game → TUI download → launch
- [ ] Test: Second play → instant (<1s)

---

## Build Commands

```bash
# Check flake evaluates
make check

# Build single kiosk
make build-amalthea

# Build all kiosks
make build-all

# Format Nix code
make fmt

# Build bubbletea-game-loader manually (for testing)
cd scripts/bubbletea-game-loader && go build -o bubbletea-game-loader .
```

---

## Notes

- **No custom kernels** — stock nixpkgs kernel (ZFS compatibility)
- **No API server** — launcher directly fetches from Myrient mirrors
- **No timers on kiosks** — all processing on europa or at build time
- **Catppuccin Mocha** — consistent with kiosk aesthetic
- **Impermanence** — `/var/cache/pegasus-roms` persists via `extraDirectories`
- **sudo helper** — extraction uses `exo-extract-helper` (from exodos.nix pattern) for overlayfs permission issues

---

## Related Issues

- #30 — Architecture (this implementation)
- #19-#32 — Individual collection archives (source data for europa)