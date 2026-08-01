#!/usr/bin/env bash
# cartridge-scrape: headless Skyscraper driver for the console ROM collections
# on europa. Emits Pegasus frontend metadata (metadata.pegasus.txt + media/)
# for each console system, with launch lines that hand off to the kiosk-side
# launch wrappers (see modules/desktop/cartridges.nix): `jupiter-retroarch
# -L <core>` for the 16 libretro systems, `jupiter-cemu` for Wii U:
#
#     launch: jupiter-retroarch -L <core> "{file.path}"
#
# Skyscraper splits scraping into two phases (see the CLI reference:
# https://gemba.github.io/skyscraper/CLIHELP/ and FRONTENDS doc):
#   1. Scrape-to-cache (-s <source>): gather resources for the platform's ROMs
#      into the resource cache. Re-runs only fetch games not already cached.
#   2. Compose (-f pegasus): emit the Pegasus metadata.pegasus.txt + composited
#      artwork from the cache into the platform's ROM directory (media/ lands
#      at <platform dir>/media by Skyscraper's pegasus default).
#
# The resource cache is what makes this idempotent and cheap to re-run: a
# second daily invocation re-reads the cache and only hits the network for
# ROMs added since the last run.
#
# Usage:
#   cartridge-scrape.sh <romRoot> <cacheDir> <source> <platform> [<platform> ...]
#
# Env:
#   SKYSCRAPER          path to the Skyscraper binary (default: "Skyscraper")
#   SCREENSCRAPER_CREDS optional path to a `USERID:PASSWORD` file; when set,
#                       ScreenScraper runs as the PRIMARY source (CRC-exact
#                       for No-Intro zips) and <source> demotes to an
#                       onlymissing gap-fill pass. Without it, <source> runs
#                       as the primary instead.
#   TGDB_APIKEY_FILE    optional path to a TheGamesDB private apikey file;
#                       passed via -u to lift the per-IP 429 when <source> is
#                       thegamesdb.

# NOTE: deliberately `set -uo pipefail` WITHOUT `-e`. This script loops every
# platform in one run (it's the jupiter-rom-scrape daily timer); with `-e` a
# single transient Skyscraper failure on the first platform would abort and
# skip the rest. Each invocation below is `|| log`-guarded instead, so a
# failed phase is logged and the run continues to the next platform/phase
# (matching cartridge-integrate.sh's resilience).
set -uo pipefail

if [ "$#" -lt 4 ]; then
  echo "usage: $0 <romRoot> <cacheDir> <source> <platform> [<platform> ...]" >&2
  exit 64
fi

ROM_ROOT=$1
CACHE_DIR=$2
SOURCE=$3
shift 3
PLATFORMS=("$@")

SKYSCRAPER=${SKYSCRAPER:-Skyscraper}

# system -> launch command prefix (the Pegasus `launch:` line written into each
# collection's metadata.pegasus.txt). 16 of 17 systems use the uniform
# `jupiter-retroarch -L <core>` path; Wii U has no libretro core, so it launches
# through the standalone `jupiter-cemu` wrapper instead. Keep in sync with
# modules/desktop/cartridges.nix's systems catalogue (the source of truth for
# cores + the cemu wrapper).
declare -A LAUNCH=(
  [nes]=jupiter-retroarch\ -L\ fceumm
  [snes]=jupiter-retroarch\ -L\ snes9x
  [gb]=jupiter-retroarch\ -L\ gambatte
  [gbc]=jupiter-retroarch\ -L\ gambatte
  [gba]=jupiter-retroarch\ -L\ mgba
  [n64]=jupiter-retroarch\ -L\ mupen64plus
  [fds]=jupiter-retroarch\ -L\ fceumm
  [virtualboy]=jupiter-retroarch\ -L\ beetle-vb
  [pokemonmini]=jupiter-retroarch\ -L\ pokemini
  [gameandwatch]=jupiter-retroarch\ -L\ gw
  [nds]=jupiter-retroarch\ -L\ desmume2015
  [dsi]=jupiter-retroarch\ -L\ desmume2015
  [gamecube]=jupiter-retroarch\ -L\ dolphin
  [wii]=jupiter-retroarch\ -L\ dolphin
  [ps1]=jupiter-retroarch\ -L\ beetle-psx
  [ps2]=jupiter-retroarch\ -L\ pcsx2
  ["3ds"]=jupiter-retroarch\ -L\ citra
  [new3ds]=jupiter-retroarch\ -L\ citra
  [wiiu]=jupiter-cemu
)

log() { printf '[cartridge-scrape] %s\n' "$*" >&2; }

for platform in "${PLATFORMS[@]}"; do
  launch=${LAUNCH[$platform]:-}
  if [ -z "$launch" ]; then
    log "no launch mapped for platform '$platform'; skipping"
    continue
  fi

  platform_dir="$ROM_ROOT/$platform"
  platform_cache="$CACHE_DIR/$platform"
  config_ini="$CACHE_DIR/config-$platform.ini"

  if [ ! -d "$platform_dir" ]; then
    log "platform dir missing: $platform_dir; skipping"
    continue
  fi

  # An empty (ROM-less) dir makes Skyscraper write an empty db.xml, zeroing the
  # cache. Count actual ROM files by extension — NOT "any file", or a stray
  # .gitkeep/.dat/dotfile would falsely pass and still zero the cache (the exact
  # regression this guards against). Recurse (no -maxdepth) so nested layouts
  # (e.g. Wii U Loadiine <game>/code/*.rpx) count too.
  rom_count=$(find "$platform_dir" -type f -regextype posix-extended \
    -iregex '.*\.(zip|iso|chd|gcm|gcz|wbfs|wad|elf|dol|ciso|cue|bin|gi|m3u|3ds|cia|cxi|cci|app|3dsx|wua|rpx|wud|wux|fds|vb|min|mgw|nds|ids|nes|sfc|smc|gb|gbc|gba|z64|n64|v64)$' \
    | wc -l)
  if [ "$rom_count" -eq 0 ]; then
    log "no ROM files in $platform_dir; skipping to protect Skyscraper cache"
    continue
  fi

  mkdir -p "$platform_cache"

  # Per-platform Skyscraper config. The [pegasus] launch line becomes the
  # collection's `launch:` field in metadata.pegasus.txt. {file.path} is the
  # Pegasus token for the ROM's path. It is wrapped in backslash-escaped quotes
  # (\\"): Qt's INI parser strips a BARE quote pair, which would otherwise leave
  # the token unquoted and word-split No-Intro paths (spaces/parens) at launch
  # time. The \\" survives Qt's parse as a literal " so Pegasus sees
  # "{file.path}".
  cat > "$config_ini" <<INI
[pegasus]
launch=${launch} \"{file.path}\"
INI

  log "scraping $platform (launch=${launch}) -> $platform_dir"

  # Phase 1: gather resources into the cache. ScreenScraper is primary when
  # creds are present (CRC-exact for No-Intro zips via --flags unpack, -t 1 for
  # the free-tier thread cap); the positional <source> (default thegamesdb)
  # then runs onlymissing to fill the gaps, so a fuzzy filename match can never
  # overwrite a correct checksum match. With no ScreenScraper creds, <source>
  # runs as the primary instead.
  # -d is the resource cache folder (the folder holding db.xml + resource
  # subdirs); --flags unattend avoids the overwrite/confirm prompts that would
  # deadlock a headless service.
  have_ss=0
  if [ -n "${SCREENSCRAPER_CREDS:-}" ] && [ -f "$SCREENSCRAPER_CREDS" ]; then
    have_ss=1
    log "  primary: ScreenScraper (CRC-exact)"
    "$SKYSCRAPER" \
      -p "$platform" \
      -s screenscraper \
      -i "$platform_dir" \
      -d "$platform_cache" \
      -c "$config_ini" \
      -u "$(cat "$SCREENSCRAPER_CREDS")" \
      -t 1 \
      --flags unattend,unpack || log "  ScreenScraper pass failed (rc=$?), continuing"
  fi

  # <source> pass: onlymissing when ScreenScraper ran (gap-fill), full scrape
  # otherwise (primary). TheGamesDB benefits from a private apikey (-u) to
  # lift the per-IP 429 that otherwise caps it near zero.
  src_flags=unattend
  src_args=()
  if [ "$have_ss" -eq 1 ]; then
    src_flags=unattend,onlymissing
    log "  secondary: $SOURCE (onlymissing)"
  else
    log "  primary: $SOURCE (no ScreenScraper creds)"
  fi
  if [ "$SOURCE" = "thegamesdb" ] && [ -n "${TGDB_APIKEY_FILE:-}" ] && [ -f "$TGDB_APIKEY_FILE" ]; then
    src_args=(-u "$(cat "$TGDB_APIKEY_FILE")")
  fi
  "$SKYSCRAPER" \
    -p "$platform" \
    -s "$SOURCE" \
    -i "$platform_dir" \
    -d "$platform_cache" \
    -c "$config_ini" \
    "${src_args[@]}" \
    --flags "$src_flags" || log "  $SOURCE pass failed (rc=$?), continuing"

  # Phase 2: compose Pegasus frontend files from the cache. -f pegasus selects
  # the frontend; -g sets the metadata.pegasus.txt output dir (the ROM dir, so
  # Pegasus finds it alongside the ROMs); media/ lands at <g>/media by default.
  # -d MUST point at the same cache phase-1 wrote to -- without it Skyscraper
  # reads its default ~/.skyscraper/cache/<platform> (empty here) and emits
  # zero game entries.
  "$SKYSCRAPER" \
    -p "$platform" \
    -f pegasus \
    -i "$platform_dir" \
    -d "$platform_cache" \
    -g "$platform_dir" \
    -c "$config_ini" \
    --flags unattend || log "  pegasus compose failed (rc=$?), continuing"

  # Rewrite absolute europa ROM/media paths to be relative to this metadata
  # dir. The kiosks mount the cartridge tree at /mnt/europa-cartridges, not
  # /tank/..., so Skyscraper's absolute paths would make Pegasus drop every
  # game + asset there. Relative paths resolve against the collection root on
  # whichever host mounts the tree. (No Skyscraper relative-path option exists
  # for the pegasus frontend.)
  sed -i "s|^\(file: \)$ROM_ROOT/$platform/|\1|; s|^\(assets\.[^:]*: \)$ROM_ROOT/$platform/|\1|" \
    "$platform_dir/metadata.pegasus.txt"
  # Drop whitespace-only lines Skyscraper emits as intra-description paragraph
  # separators -- Pegasus treats them as entry-ending blank lines and rejects
  # the next indented continuation. Truly-empty (0-char) separators survive.
  sed -i '/^[[:space:]][[:space:]]*$/d' "$platform_dir/metadata.pegasus.txt"
done

log "done: ${#PLATFORMS[@]} platform(s) processed"
