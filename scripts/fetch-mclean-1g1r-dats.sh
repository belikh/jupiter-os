#!/usr/bin/env bash
# fetch-mclean-1g1r-dats.sh — Download McLean 1G1R DAT files from Fresh1G1R
# Run on europa to populate /tank/archive/retro/metadata/no-intro-dats/

set -euo pipefail

DAT_DIR="/tank/archive/retro/metadata/no-intro-dats"
mkdir -p "$DAT_DIR"

BASE_URL="https://raw.githubusercontent.com/UnluckyForSome/Fresh1G1R/main/daily-1g1r-dat/McLean"

# No-Intro cartridge systems
declare -A NOINTRO_DATS=(
    ["nes.dat"]="no-intro/Nintendo%20-%20Nintendo%20Entertainment%20System%20%28Headerless%29%20%28No-Intro%20-%20Fresh1G1R%20-%20McLean%29.dat"
    ["snes.dat"]="no-intro/Nintendo%20-%20Super%20Nintendo%20Entertainment%20System%20%28No-Intro%20-%20Fresh1G1R%20-%20McLean%29.dat"
    ["gb.dat"]="no-intro/Nintendo%20-%20Game%20Boy%20%28No-Intro%20-%20Fresh1G1R%20-%20McLean%29.dat"
    ["gbc.dat"]="no-intro/Nintendo%20-%20Game%20Boy%20Color%20%28No-Intro%20-%20Fresh1G1R%20-%20McLean%29.dat"
    ["gba.dat"]="no-intro/Nintendo%20-%20Game%20Boy%20Advance%20%28No-Intro%20-%20Fresh1G1R%20-%20McLean%29.dat"
    ["n64.dat"]="no-intro/Nintendo%20-%20Nintendo%2064%20%28BigEndian%29%20%28No-Intro%20-%20Fresh1G1R%20-%20McLean%29.dat"
    ["fds.dat"]="no-intro/Nintendo%20-%20Family%20Computer%20Disk%20System%20%28FDS%29%20%28No-Intro%20-%20Fresh1G1R%20-%20McLean%29.dat"
    ["virtualboy.dat"]="no-intro/Nintendo%20-%20Virtual%20Boy%20%28No-Intro%20-%20Fresh1G1R%20-%20McLean%29.dat"
    ["pokemonmini.dat"]="no-intro/Nintendo%20-%20Pokemon%20Mini%20%28No-Intro%20-%20Fresh1G1R%20-%20McLean%29.dat"
    ["gameandwatch.dat"]="no-intro/Nintendo%20-%20Game%20%26%20Watch%20%28No-Intro%20-%20Fresh1G1R%20-%20McLean%29.dat"
    ["nds.dat"]="no-intro/Nintendo%20-%20Nintendo%20DS%20%28Decrypted%29%20%28No-Intro%20-%20Fresh1G1R%20-%20McLean%29.dat"
    ["dsi.dat"]="no-intro/Nintendo%20-%20Nintendo%20DSi%20%28Decrypted%29%20%28No-Intro%20-%20Fresh1G1R%20-%20McLean%29.dat"
    ["3ds.dat"]="no-intro/Nintendo%20-%20Nintendo%203DS%20%28Decrypted%29%20%28No-Intro%20-%20Fresh1G1R%20-%20McLean%29.dat"
    ["new3ds.dat"]="no-intro/Nintendo%20-%20New%20Nintendo%203DS%20%28Decrypted%29%20%28No-Intro%20-%20Fresh1G1R%20-%20McLean%29.dat"
)

# Redump optical systems (GameCube, Wii)
declare -A REDUMP_DATS=(
    ["gamecube.dat"]="redump/Nintendo%20-%20GameCube%20%28Redump%20-%20Fresh1G1R%20-%20McLean%29.dat"
    ["wii.dat"]="redump/Nintendo%20-%20Wii%20%28Redump%20-%20Fresh1G1R%20-%20McLean%29.dat"
)

echo "Fetching No-Intro McLean 1G1R DATs..."
for dat_file in "${!NOINTRO_DATS[@]}"; do
    url="${BASE_URL}/${NOINTRO_DATS[$dat_file]}"
    echo "  $dat_file <- $url"
    wget -q --show-progress -O "$DAT_DIR/$dat_file" "$url" || echo "    WARNING: Failed to fetch $dat_file"
done

echo "Fetching Redump McLean 1G1R DATs..."
for dat_file in "${!REDUMP_DATS[@]}"; do
    url="${BASE_URL}/${REDUMP_DATS[$dat_file]}"
    echo "  $dat_file <- $url"
    wget -q --show-progress -O "$DAT_DIR/$dat_file" "$url" || echo "    WARNING: Failed to fetch $dat_file"
done

echo "Done. DAT files in $DAT_DIR:"
ls -la "$DAT_DIR"/*.dat 2>/dev/null || echo "  (none)"