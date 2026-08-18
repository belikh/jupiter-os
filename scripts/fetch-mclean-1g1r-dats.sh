#!/usr/bin/env bash
# fetch-mclean-1g1r-dats.sh — Download McLean 1G1R DAT files from Fresh1G1R.
#
# Run on europa to populate /tank/archive/retro/metadata/no-intro-dats/
# (the jupiter.services.romAcquire.datDir), one <system>.dat per console in
# scripts/cartridge-catalogue.tsv, so igir can verify each staged set before
# promotion (cartridge-verify.sh) instead of degrading to promote-as-is.
#
# DAT names below are pinned to the Fresh1G1R "McLean" 1G1R set
# (daily-1g1r-dat/McLean/{no-intro,redump}/), which is the canonical 1G1R
# source for No-Intro + Redump ROMs. The catalogue's torrent basenames cannot
# be mechanically mapped to DAT basenames (the torrent collection labels
# "Non-Redump" and "RetroAchievements" do not match DAT collections, and a few
# system names differ), so this table is the explicit mapping — verified
# against the Fresh1G1R repo on 2026-08-18. Systems with NO exact McLean DAT
# (wiiu, pcfx, zxspectrum) are intentionally absent; verify treats a missing
# DAT as promote-without-checking for that system.
#
# DATs are non-redistributable (No-Intro/Redump terms) — fetched at runtime,
# never committed to the repo (see ADR-0001). Idempotent: re-downloading
# overwrites in place.

set -euo pipefail

DAT_DIR="${DAT_DIR:-/tank/archive/retro/metadata/no-intro-dats}"
BASE_URL="https://raw.githubusercontent.com/UnluckyForSome/Fresh1G1R/main/daily-1g1r-dat/McLean"

# system -> "collection/DAT basename"; collection is no-intro/ or redump/.
declare -A DATS=(
  # No-Intro Nintendo cartridge systems
  ["nes"]="no-intro/Nintendo - Nintendo Entertainment System (Headerless) (No-Intro - Fresh1G1R - McLean).dat"
  ["snes"]="no-intro/Nintendo - Super Nintendo Entertainment System (No-Intro - Fresh1G1R - McLean).dat"
  ["gb"]="no-intro/Nintendo - Game Boy (No-Intro - Fresh1G1R - McLean).dat"
  ["gbc"]="no-intro/Nintendo - Game Boy Color (No-Intro - Fresh1G1R - McLean).dat"
  ["gba"]="no-intro/Nintendo - Game Boy Advance (No-Intro - Fresh1G1R - McLean).dat"
  ["n64"]="no-intro/Nintendo - Nintendo 64 (BigEndian) (No-Intro - Fresh1G1R - McLean).dat"
  ["fds"]="no-intro/Nintendo - Family Computer Disk System (FDS) (No-Intro - Fresh1G1R - McLean).dat"
  ["virtualboy"]="no-intro/Nintendo - Virtual Boy (No-Intro - Fresh1G1R - McLean).dat"
  ["pokemonmini"]="no-intro/Nintendo - Pokemon Mini (No-Intro - Fresh1G1R - McLean).dat"
  ["gameandwatch"]="no-intro/Nintendo - Game & Watch (No-Intro - Fresh1G1R - McLean).dat"
  ["nds"]="no-intro/Nintendo - Nintendo DS (Decrypted) (No-Intro - Fresh1G1R - McLean).dat"
  ["dsi"]="no-intro/Nintendo - Nintendo DSi (Decrypted) (No-Intro - Fresh1G1R - McLean).dat"
  ["3ds"]="no-intro/Nintendo - Nintendo 3DS (Decrypted) (No-Intro - Fresh1G1R - McLean).dat"
  ["new3ds"]="no-intro/Nintendo - New Nintendo 3DS (Decrypted) (No-Intro - Fresh1G1R - McLean).dat"
  # No-Intro Sega
  ["sms"]="no-intro/Sega - Master System - Mark III (No-Intro - Fresh1G1R - McLean).dat"
  ["megadrive"]="no-intro/Sega - Mega Drive - Genesis (No-Intro - Fresh1G1R - McLean).dat"
  ["gamegear"]="no-intro/Sega - Game Gear (No-Intro - Fresh1G1R - McLean).dat"
  ["sega32x"]="no-intro/Sega - 32X (No-Intro - Fresh1G1R - McLean).dat"
  ["sg1000"]="no-intro/Sega - SG-1000 - SC-3000 (No-Intro - Fresh1G1R - McLean).dat"
  # No-Intro NEC
  ["pce"]="no-intro/NEC - PC Engine - TurboGrafx-16 (No-Intro - Fresh1G1R - McLean).dat"
  ["supergrafx"]="no-intro/NEC - PC Engine SuperGrafx (No-Intro - Fresh1G1R - McLean).dat"
  # No-Intro SNK
  ["ngp"]="no-intro/SNK - NeoGeo Pocket (No-Intro - Fresh1G1R - McLean).dat"
  ["ngpc"]="no-intro/SNK - NeoGeo Pocket Color (No-Intro - Fresh1G1R - McLean).dat"
  # No-Intro Commodore / Microsoft / misc cartridge systems
  ["c64"]="no-intro/Commodore - Commodore 64 (No-Intro - Fresh1G1R - McLean).dat"
  ["vic20"]="no-intro/Commodore - VIC-20 (No-Intro - Fresh1G1R - McLean).dat"
  ["plus4"]="no-intro/Commodore - Plus-4 (No-Intro - Fresh1G1R - McLean).dat"
  ["amiga"]="no-intro/Commodore - Amiga (No-Intro - Fresh1G1R - McLean).dat"
  ["msx"]="no-intro/Microsoft - MSX (No-Intro - Fresh1G1R - McLean).dat"
  ["msx2"]="no-intro/Microsoft - MSX2 (No-Intro - Fresh1G1R - McLean).dat"
  ["coleco"]="no-intro/Coleco - ColecoVision (No-Intro - Fresh1G1R - McLean).dat"
  ["intellivision"]="no-intro/Mattel - Intellivision (No-Intro - Fresh1G1R - McLean).dat"
  ["vectrex"]="no-intro/GCE - Vectrex (No-Intro - Fresh1G1R - McLean).dat"
  ["odyssey2"]="no-intro/Magnavox - Odyssey 2 (No-Intro - Fresh1G1R - McLean).dat"
  ["videopac"]="no-intro/Philips - Videopac+ (No-Intro - Fresh1G1R - McLean).dat"
  ["apple2"]="no-intro/Apple - II (WOZ) (No-Intro - Fresh1G1R - McLean).dat"
  # No-Intro Atari
  ["a2600"]="no-intro/Atari - Atari 2600 (No-Intro - Fresh1G1R - McLean).dat"
  ["a5200"]="no-intro/Atari - Atari 5200 (No-Intro - Fresh1G1R - McLean).dat"
  ["a7800"]="no-intro/Atari - Atari 7800 (BIN) (No-Intro - Fresh1G1R - McLean).dat"
  ["a800"]="no-intro/Atari - 8-bit Family (No-Intro - Fresh1G1R - McLean).dat"
  ["lynx"]="no-intro/Atari - Atari Lynx (LYX) (No-Intro - Fresh1G1R - McLean).dat"
  ["jaguar"]="no-intro/Atari - Atari Jaguar (J64) (No-Intro - Fresh1G1R - McLean).dat"
  ["atari_st"]="no-intro/Atari - Atari ST (No-Intro - Fresh1G1R - McLean).dat"
  # Redump optical systems. NOTE: gamecube/wii/ps1/ps2 torrents are labelled
  # "Non-Redump"/"RetroAchievements" but the Fresh1G1R DATs live in redump/.
  ["gamecube"]="redump/Nintendo - GameCube (Redump - Fresh1G1R - McLean).dat"
  ["wii"]="redump/Nintendo - Wii (Redump - Fresh1G1R - McLean).dat"
  ["segacd"]="redump/Sega - Mega CD & Sega CD (Redump - Fresh1G1R - McLean).dat"
  ["saturn"]="redump/Sega - Saturn (Redump - Fresh1G1R - McLean).dat"
  ["dreamcast"]="redump/Sega - Dreamcast (Redump - Fresh1G1R - McLean).dat"
  ["psp"]="redump/Sony - PlayStation Portable (Redump - Fresh1G1R - McLean).dat"
  ["ps1"]="redump/Sony - PlayStation (Redump - Fresh1G1R - McLean).dat"
  ["ps2"]="redump/Sony - PlayStation 2 (Redump - Fresh1G1R - McLean).dat"
  ["jaguar_cd"]="redump/Atari - Jaguar CD Interactive Multimedia System (Redump - Fresh1G1R - McLean).dat"
  ["pce_cd"]="redump/NEC - PC Engine CD & TurboGrafx CD (Redump - Fresh1G1R - McLean).dat"
  ["pc98"]="redump/NEC - PC-98 series (Redump - Fresh1G1R - McLean).dat"
  ["neocd"]="redump/SNK - Neo Geo CD (Redump - Fresh1G1R - McLean).dat"
  ["amiga_cd"]="redump/Commodore - Amiga CD (Redump - Fresh1G1R - McLean).dat"
  ["amiga_cd32"]="redump/Commodore - Amiga CD32 (Redump - Fresh1G1R - McLean).dat"
  ["amiga_cdtv"]="redump/Commodore - Amiga CDTV (Redump - Fresh1G1R - McLean).dat"
  ["fmtowns"]="redump/Fujitsu - FM-Towns (Redump - Fresh1G1R - McLean).dat"
)

mkdir -p "$DAT_DIR"

# Fresh1G1R filenames contain spaces and parens; jq @uri percent-encodes them.
# It also encodes "/", which we need to keep for the collection path prefix.
enc() {
  printf '%s' "$1" | jq -sRr '@uri' | sed 's|%2F|/|g'
}

ok=0
for sys in "${!DATS[@]}"; do
  rel="${DATS[$sys]}"
  url="${BASE_URL}/$(enc "$rel")"
  if curl -fsS --max-time 60 -o "$DAT_DIR/$sys.dat" "$url"; then
    echo "  $sys.dat <- $rel"
    ok=$((ok + 1))
  else
    echo "  WARNING: failed to fetch $sys.dat ($url)" >&2
  fi
done

echo "Done. $ok DAT file(s) in $DAT_DIR:"
ls -la "$DAT_DIR"/*.dat 2>/dev/null | awk '{print "  " $5 " " $NF}' || echo "  (none)"