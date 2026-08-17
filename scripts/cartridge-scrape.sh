#!/usr/bin/env bash
# cartridge-scrape: headless Skyscraper driver for the console ROM collections
# on europa. Emits Pegasus frontend metadata (metadata.pegasus.txt + media/)
# for each console system, with launch lines that hand off to the kiosk-side
# launch wrappers (see modules/desktop/cartridges.nix): `jupiter-retroarch
# -L <core>` for the 18 libretro-core systems, `jupiter-cemu` for Wii U:
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
# Launchability never depends on the scrape succeeding: whenever a platform's
# metadata.pegasus.txt is missing, empty, or lacks a `launch:` line after
# Skyscraper's compose (empty resource cache -> 0-byte file), a minimal
# fallback (header + launch + explicit per-game file entries) is seeded so
# the games RUN; enrichment replaces it on the next successful scrape.
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

# THE console-system catalogue — parsed at runtime from the committed TSV
# (JUPITER_CATALOGUE_TSV; defaults to the repo copy beside this script for
# standalone runs — the Nix module copies it into the store because a store
# script can't see the repo tree). This REPLACES four hand-synced bash maps
# (LAUNCH / SKYPLATFORM / COLLECTIONS / ROM_RE) that used to drift from the
# Nix-side catalogues; adding or removing a system is ONE row in
# scripts/cartridge-catalogue.tsv, and modules/services/arcade-catalogue.nix
# derives its option from the same file.
CATALOGUE_TSV=${JUPITER_CATALOGUE_TSV:-"$(dirname "$0")/cartridge-catalogue.tsv"}
if [ ! -r "$CATALOGUE_TSV" ]; then
  echo "$0: catalogue TSV not readable: $CATALOGUE_TSV (set JUPITER_CATALOGUE_TSV)" >&2
  exit 64
fi

declare -A LAUNCH SKYPLATFORM COLLECTIONS
GLOBAL_RE='.*\.('
while IFS=$'\t' read -r sys collection core emulator extensions sky bucket torrent; do
  case "$sys" in ''|'#'*) continue ;; esac
  # launch: uniform 'jupiter-retroarch -L <core>' path; systems with no
  # libretro core (core "-") launch through their standalone wrapper.
  if [ "$core" != "-" ]; then
    LAUNCH[$sys]="jupiter-retroarch -L $core"
  elif [ "$emulator" != "-" ]; then
    LAUNCH[$sys]="jupiter-$emulator"
  fi
  # Skyscraper's -p handle when it differs from our dir key (ps1->psx,
  # gamecube->gc, pokemonmini->pokemini, dsi->nds, new3ds->3ds).
  [ "$sky" != "-" ] && SKYPLATFORM[$sys]="$sky"
  COLLECTIONS[$sys]="$collection"
  GLOBAL_RE="$GLOBAL_RE${extensions//,/|}|"
done < "$CATALOGUE_TSV"
# global extras no per-system list carries: No-Intro cartridge sets ship as
# .zip archives, and cue/bin pairs travel together.
GLOBAL_RE="$GLOBAL_RE"'zip|bin)'
ROM_RE="$GLOBAL_RE"

# Ensure the platform's metadata.pegasus.txt is LAUNCHABLE: if Skyscraper's
# compose left it missing, empty, or without a `launch:` line (the empty-cache
# case: compose writes a 0-byte file), emit a minimal fallback — collection
# header + launch line + one explicit `game:`/`file:` entry per ROM, the same
# entry shape Skyscraper's enriched files use, so nested No-Intro trees list
# correctly. Games become launchable the moment this runs; a later successful
# scrape overwrites it with enriched metadata (titles, art) — that overwrite
# always carries a launch line, so this never masks enrichment.
seed_launchable_metadata() {
  local md="$platform_dir/metadata.pegasus.txt"
  if [ -s "$md" ] && grep -q '^launch: ' "$md"; then
    return 0
  fi
  log "  metadata missing/launch-less; seeding minimal launchable metadata"
  local title=${COLLECTIONS[$platform]:-$platform}
  {
    printf 'collection: %s\n' "$title"
    printf 'shortname: %s\n' "$platform"
    printf 'launch: %s "{file.path}"\n' "$launch"
    printf '\n'
    local rel base
    while IFS= read -r rel; do
      rel=${rel#./}
      base=${rel##*/}
      base=${base%.*}
      [ -n "$base" ] || continue
      # Pegasus' metafile parser (MetaFile.cpp) has NO quoting: a value is
      # everything after the first ':', trimmed. So both game: and file:
      # values stay raw — quotes would render literally in titles and break
      # file paths (verified live 2026-08-16: double-quoted file: values
      # were kept in the path and every entry was rejected). Colons in
      # values are safe (first-colon split).
      printf 'game: %s\nfile: %s\n\n' "$base" "$rel"
    done < <(
      cd "$platform_dir" \
        && find . -type f -regextype posix-extended -iregex "$ROM_RE" | LC_ALL=C sort
    )
  } > "$md"
}

# A ROM is "complete" when its magic bytes match its format. While aria2 is
# still torrenting a set it PREALLOCATES every file as zeros — the file
# exists at full size but its header is 0x00000000, and the emulator aborts
# on it (observed: pcsx2 "chd_open return error: invalid data" on a 715MB
# all-zero .chd). Only formats with a reliable leading magic are checked;
# everything else is optimistically complete (a raw .iso CAN legitimately
# start with zeros — its descriptors live at offset 32768 — so isos are not
# checkable this way).
rom_complete() { # $1 = absolute path to the ROM file
  local magic
  case "$1" in
    *.chd | *.CHD)
      IFS= read -r -N 8 magic < "$1" 2>/dev/null || magic=""
      [ "$magic" = "MComprHD" ] || case "$magic" in ComprHD*) true ;; *) false ;; esac
      ;;
    *.zip | *.ZIP)
      IFS= read -r -N 2 magic < "$1" 2>/dev/null || magic=""
      [ "$magic" = "PK" ]
      ;;
    *)
      return 0
      ;;
  esac
}

# Split the platform's metadata into playable vs PENDING: game blocks whose
# file fails rom_complete move out of the main collection into an appended
# "<Title> (Pending)" collection (same file — Pegasus supports multiple
# collections per metadata file, and entries belong to the last-declared
# collection). The pending collection deliberately has NO launch line, so
# its entries are listed but not launchable — "coming soon", not a dead
# black-screen launch. Idempotent: any previously appended pending section
# (everything from PENDING_MARKER to EOF) is stripped and rebuilt, so games
# migrate back into the main collection automatically once their download
# finishes and the next run re-checks them.
split_pending() {
  local md="$platform_dir/metadata.pegasus.txt"
  [ -s "$md" ] || return 0

  # Incomplete ROMs (relative paths), if any.
  local tmplist rel
  tmplist=$(mktemp)
  while IFS= read -r rel; do
    rel=${rel#./}
    rom_complete "$platform_dir/$rel" || printf '%s\n' "$rel" >> "$tmplist"
  done < <(cd "$platform_dir" && find . -type f -regextype posix-extended -iregex "$ROM_RE" | LC_ALL=C sort)

  # Nothing incomplete and no stale pending section -> leave the file alone
  # (avoids rewriting enriched metadata every night for no reason).
  if [ ! -s "$tmplist" ] && ! grep -qF "$PENDING_MARKER" "$md"; then
    rm -f "$tmplist"
    return 0
  fi

  local title=${COLLECTIONS[$platform]:-$platform}
  local tmpmd
  tmpmd=$(mktemp)
  # Single rebuild pass. Every game block in the file — main body OR a
  # previously appended pending section — is re-classified against the
  # current completeness list, so games migrate main<->pending as their
  # downloads progress. The main header (everything before the first
  # game:) is preserved verbatim; our own marker line and the pending
  # section's collection-level property lines are dropped and re-emitted.
  # Output is assembled in memory (header, playable blocks, then the new
  # pending section) so ordering stays deterministic.
  awk -v listfile="$tmplist" -v marker="$PENDING_MARKER" \
    -v pendcol="$title (Pending)" -v pendshort="${platform}-pending" '
    BEGIN {
      while ((getline line < listfile) > 0) bad[line] = 1
      close(listfile)
      ingame = 0; buf = ""; nmain = 0; pend = ""; seenfirst = 0
    }
    index($0, marker) == 1 { next }
    /^game:/ {
      if (ingame) flushgame()
      ingame = 1; seenfirst = 1; buf = $0
      next
    }
    # A collection-level property line AFTER the first game can only be ours
    # (from the old pending section — Skyscraper emits game fields inline
    # inside blocks, and the main header never follows games). Before the
    # first game these same lines ARE the main header: keep them. This must
    # run BEFORE the ingame accumulator, else the lines get swallowed into
    # the buffer of the preceding game block.
    seenfirst && /^(collection|shortname|summary): / { next }
    ingame { buf = buf "\n" $0; next }
    { header = header $0 "\n" }
    function flushgame(   path, n, i) {
      path = ""
      n = split(buf, lines, "\n")
      for (i = 1; i <= n; i++) {
        if (lines[i] ~ /^file: ./) {
          path = substr(lines[i], 7)
          sub(/^[[:space:]]+/, "", path)
          sub(/[[:space:]]+$/, "", path)
          break
        }
      }
      # Normalize: drop trailing blank lines picked up between blocks so
      # re-parsing a previously processed file reproduces identical output
      # (idempotency).
      gsub(/\n[[:space:]]*\n+$/, "\n", buf)
      if (path != "" && (path in bad))
        pend = pend buf "\n\n"
      else
        main[++nmain] = buf "\n\n"
      buf = ""
    }
    END {
      if (ingame) flushgame()
      printf "%s", header
      for (i = 1; i <= nmain; i++) printf "%s", main[i]
      if (pend != "") {
        print ""
        print marker
        print "collection: " pendcol
        print "shortname: " pendshort
        print "summary: Still downloading or incomplete - listed but not yet playable."
        print ""
        printf "%s", pend
      }
    }
  ' "$md" > "$tmpmd" && mv "$tmpmd" "$md" || rm -f "$tmpmd"
  rm -f "$tmplist"
  log "  pending split: incomplete ROMs moved to '${title} (Pending)'"
}

for platform in "${PLATFORMS[@]}"; do
  launch=${LAUNCH[$platform]:-}
  if [ -z "$launch" ]; then
    log "no launch mapped for platform '$platform'; skipping"
    continue
  fi
  skyplatform=${SKYPLATFORM[$platform]:-$platform}

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
    -iregex "$ROM_RE" \
    | wc -l)
  if [ "$rom_count" -eq 0 ]; then
    log "no ROM files in $platform_dir; skipping to protect Skyscraper cache"
    continue
  fi

  mkdir -p "$platform_cache"

  # Launchability must not depend on scrape-source health: seed the fallback
  # BEFORE the network phases so the collection is playable immediately, and
  # again after compose below in case Skyscraper zeroed it (empty cache).
  seed_launchable_metadata

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

  log "scraping $platform (skyscraper=$skyplatform, launch=${launch}) -> $platform_dir"

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
      -p "$skyplatform" \
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
    -p "$skyplatform" \
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
    -p "$skyplatform" \
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

  # Post-compose repair pass: if Skyscraper wrote an empty/launch-less file
  # (its cache was empty), the pre-seeded fallback was overwritten with a
  # 0-byte one — re-seed so the collection stays launchable.
  seed_launchable_metadata

  # Finally, split incomplete-download ROMs into the "(Pending)" collection
  # so only playable games appear (launchable) in the main collection.
  split_pending
done

log "done: ${#PLATFORMS[@]} platform(s) processed"
