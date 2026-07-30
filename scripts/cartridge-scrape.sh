#!/usr/bin/env bash
# cartridge-scrape: headless Skyscraper driver for the cartridge ROM
# collections on europa. Emits Pegasus frontend metadata (metadata.pegasus.txt
# + media/) for each cartridge system, with launch lines that hand off to the
# kiosk-side `jupiter-retroarch` wrapper (see modules/desktop/cartridges.nix):
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
#                       an additional ScreenScraper cache pass runs (-u) to
#                       fill gaps left by the primary source.

set -euo pipefail

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

# system -> libretro core (the value passed to `jupiter-retroarch -L`).
# Keep in sync with modules/desktop/cartridges.nix's core wiring.
declare -A CORES=(
  [nes]=fceumm
  [snes]=snes9x
  [gb]=gambatte
  [gbc]=gambatte
  [gba]=mgba
  [n64]=mupen64plus
)

log() { printf '[cartridge-scrape] %s\n' "$*" >&2; }

for platform in "${PLATFORMS[@]}"; do
  core=${CORES[$platform]:-}
  if [ -z "$core" ]; then
    log "no core mapped for platform '$platform'; skipping"
    continue
  fi

  platform_dir="$ROM_ROOT/$platform"
  platform_cache="$CACHE_DIR/$platform"
  config_ini="$CACHE_DIR/config-$platform.ini"

  if [ ! -d "$platform_dir" ]; then
    log "platform dir missing: $platform_dir; skipping"
    continue
  fi

  mkdir -p "$platform_cache"

  # Per-platform Skyscraper config. The [pegasus] launch line becomes every
  # game entry's `launch:` field in metadata.pegasus.txt. {file.path} is the
  # Pegasus token for the ROM's path. The value is written unquoted so the
  # embedded quotes around {file.path} survive Qt's INI value parsing verbatim
  # (Qt only strips a quote pair that wraps the *whole* value).
  cat > "$config_ini" <<INI
[pegasus]
launch=jupiter-retroarch -L ${core} "{file.path}"
INI

  log "scraping $platform (core=$core, source=$SOURCE) -> $platform_dir"

  # Phase 1: gather resources from the scraping source into the cache.
  # -d is the resource cache folder (Skyscraper expects a per-platform folder
  # holding db.xml + resource subdirs); --flags unattend avoids the
  # overwrite/confirm prompts that would deadlock a headless service.
  "$SKYSCRAPER" \
    -p "$platform" \
    -s "$SOURCE" \
    -i "$platform_dir" \
    -d "$platform_cache" \
    -c "$config_ini" \
    --flags unattend

  # Optional ScreenScraper enrichment pass: only when creds are provided and
  # only for games the primary source missed (onlymissing), so the cache fills
  # without re-fetching everything ScreenScraper-side.
  if [ -n "${SCREENSCRAPER_CREDS:-}" ] && [ -f "$SCREENSCRAPER_CREDS" ]; then
    log "enriching $platform from ScreenScraper"
    "$SKYSCRAPER" \
      -p "$platform" \
      -s screenscraper \
      -i "$platform_dir" \
      -d "$platform_cache" \
      -c "$config_ini" \
      -u "$(cat "$SCREENSCRAPER_CREDS")" \
      --flags unattend,onlymissing
  fi

  # Phase 2: compose Pegasus frontend files from the cache. -f pegasus selects
  # the frontend; -g sets the metadata.pegasus.txt output dir (the ROM dir, so
  # Pegasus finds it alongside the ROMs); media/ lands at <g>/media by default.
  "$SKYSCRAPER" \
    -p "$platform" \
    -f pegasus \
    -i "$platform_dir" \
    -g "$platform_dir" \
    -c "$config_ini" \
    --flags unattend
done

log "done: ${#PLATFORMS[@]} platform(s) processed"
