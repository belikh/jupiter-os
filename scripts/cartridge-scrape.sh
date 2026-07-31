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
#                       ScreenScraper runs as the PRIMARY source (CRC-exact
#                       for No-Intro zips) and <source> demotes to an
#                       onlymissing gap-fill pass. Without it, <source> runs
#                       as the primary instead.
#   TGDB_APIKEY_FILE    optional path to a TheGamesDB private apikey file;
#                       passed via -u to lift the per-IP 429 when <source> is
#                       thegamesdb.

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

  log "scraping $platform (core=$core) -> $platform_dir"

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
      --flags unattend,unpack
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
    --flags "$src_flags"

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
    --flags unattend
done

log "done: ${#PLATFORMS[@]} platform(s) processed"
