#!/usr/bin/env bash
# DEPRECATED 2026-08 — superseded by the declarative pipeline
# (modules/services/rom-acquire.nix jupiter-rom-acquire + jupiter-rom-verify,
# modules/services/rom-scraper.nix jupiter-rom-scrape). Kept as the
# operational record of the initial No-Intro bulk load. DO NOT RUN against
# the live tree: its promote path moves staged ROMs into games/cartridge
# WITHOUT the igir DAT verification that jupiter-rom-verify exists to
# perform, and its minimal metadata writes an UNQUOTED {file.path} launch
# token that word-splits No-Intro paths (spaces/parens) at launch time.
#
# cartridge-integrate: persistent watcher. As aria2 marks each No-Intro
# Nintendo cartridge system complete, it (A) promotes the ROMs into the
# playable tree + writes a minimal Pegasus collection file so the system is
# LAUNCHABLE immediately, then (B) enriches ONE system per pass with full
# Skyscraper metadata + art (serial — parallel scraping trips TGDB limits).
#
# "Complete" = incoming dir has ROMs but NO aria2 control file (aria2 deletes
# .aria2 on completion). Idempotent via .promoted / .scraped flags in $STATE.
set -uo pipefail

# systemd-run units carry a minimal PATH that can't resolve bash/coreutils/
# Skyscraper on NixOS. Pin the system profile + root nix-profile.
export PATH=/run/current-system/sw/bin:/root/.nix-profile/bin:/usr/bin:/bin

CACHE=/tank/archive/retro/cache/incoming/nointro-nintendo
CART=/tank/archive/retro/games/cartridge
SKCACHE=/tank/archive/retro/metadata/skyscraper-cache
SCRATCH=/tank/archive/retro/scratch
STATE=$SCRATCH/integrated
LOG=$SCRATCH/cartridge-integrate.log
mkdir -p "$CART" "$SKCACHE" "$STATE"

SKY="${SKY:-Skyscraper}"
if ! command -v "$SKY" >/dev/null 2>&1; then
  echo "FATAL: $SKY not on PATH (run: nix profile install nixpkgs#skyscraper)" >&2
  exit 1
fi

# Scraping credentials. On europa's real closure these are activation-time
# sops secrets (SCREENSCRAPER_CREDS / TGDB_APIKEY_FILE set by rom-scraper.nix
# to /run/secrets/... paths); for the live scratch run, drop the same values
# at these pool paths. ScreenScraper is the primary source (CRC-exact for
# No-Intro zips via --flags unpack); TheGamesDB runs keyed + onlymissing to
# fill what ScreenScraper missed (it is filename-fuzzy, so it must come second
# and never overwrite correct checksum matches).
SSCREDS_FILE="${SCREENSCRAPER_CREDS:-$SCRATCH/screenscraper-creds}"
TGDBKEY_FILE="${TGDB_APIKEY_FILE:-$SCRATCH/tgdb-apikey}"

# sys | libretro core | Skyscraper platform | collection title
SYSTEMS=(
  "nes|fceumm|nes|Nintendo Entertainment System"
  "snes|snes9x|snes|Super Nintendo Entertainment System"
  "gb|gambatte|gb|Nintendo Game Boy"
  "gbc|gambatte|gbc|Nintendo Game Boy Color"
  "gba|mgba|gba|Nintendo Game Boy Advance"
  "n64|mupen64plus|n64|Nintendo 64"
)

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2; }

write_minimal() {
  # $1 sys $2 core $3 title -> a launchable-but-bare Pegasus collection file.
  # `extension: zip` makes Pegasus auto-list every .zip in the dir as a game,
  # each launched via the collection launch line — no per-game entries needed,
  # so the system is playable the moment this is written. Skyscraper's phase-2
  # pass later overwrites it with a richer per-game version (titles + assets).
  local sys=$1 core=$2 title=$3
  cat > "$CART/$sys/metadata.pegasus.txt" <<META
collection: $title
shortname: $sys
extension: zip
launch: jupiter-retroarch -L $core "{file.path}"
META
}

promote_if_complete() {
  local entry=$1 sys core plat title src ctrl cachezips cartzips
  IFS='|' read -r sys core plat title <<< "$entry"
  [ -f "$STATE/$sys.promoted" ] && return
  src="$CACHE/$sys"
  # Still downloading? (aria2 control files present -> not done yet.)
  if [ -d "$src" ]; then
    ctrl=$(find "$src" -name '*.aria2' 2>/dev/null | wc -l)
    if [ "$ctrl" -ne 0 ]; then
      log "$sys: still downloading ($ctrl control file(s))"
      return
    fi
    cachezips=$(find "$src" -name '*.zip' 2>/dev/null | wc -l)
    if [ "$cachezips" -gt 0 ]; then
      log "$sys: COMPLETE on disk ($cachezips ROMs) -> promoting"
      mkdir -p "$CART/$sys"
      # Flatten the Minerva_Myrient/No-Intro/Nintendo - <Set>/ nesting so ROMs
      # sit directly under <CART>/<sys>/ (the layout the kiosks NFS-mount).
      find "$src" -name '*.zip' -exec mv -t "$CART/$sys/" {} + 2>/dev/null \
        || find "$src" -name '*.zip' -exec mv {} "$CART/$sys/" \;
    fi
  fi
  # ROMs now in cart (just moved, or moved by a prior run)? -> minimal metadata.
  cartzips=$(find "$CART/$sys" -name '*.zip' 2>/dev/null | wc -l)
  [ "$cartzips" -gt 0 ] || return
  write_minimal "$sys" "$core" "$title"
  touch "$STATE/$sys.promoted"
  log "$sys: PROMOTED — launchable in Pegasus ($cartzips ROMs, minimal metadata)"
}

scrape_one() {
  # Scrape exactly one promoted-but-not-scraped system per pass (serial ->
  # rate-limit safe). Returns 0 if it scraped one, 1 if none eligible.
  local entry sys core plat title cfg
  for entry in "${SYSTEMS[@]}"; do
    IFS='|' read -r sys core plat title <<< "$entry"
    [ -f "$STATE/$sys.scraped" ] && continue
    [ -f "$STATE/$sys.promoted" ] || continue
    [ "$(find "$CART/$sys" -name '*.zip' 2>/dev/null | wc -l)" -gt 0 ] || continue
    log "$sys: enriching (platform=$plat core=$core) with Skyscraper/ TGDB"
    cfg="$SKCACHE/config-$sys.ini"
    mkdir -p "$SKCACHE/$plat"
    # {file.path} is wrapped in backslash-escaped quotes (\\") rather than bare
    # quotes: Qt's INI parser strips a bare quote pair, which left unescaped
    # would make Skyscraper emit `launch: ... {file.path}` (unquoted) and
    # word-split No-Intro paths (spaces/parens) at launch time. \\" survives
    # Qt's parse as a literal " so Pegasus sees `... "{file.path}"`.
    # (matches scripts/cartridge-scrape.sh)
    printf '[pegasus]\nlaunch=jupiter-retroarch -L %s \\"{file.path}\\"\n' "$core" > "$cfg"
    # Build per-source credential args. ScreenScraper wants USERID:PASSWORD;
    # TheGamesDB wants its private apikey (both passed via Skyscraper's -u).
    local ss_args=() tgdb_args=()
    if [ -s "$SSCREDS_FILE" ]; then
      ss_args=(-u "$(cat "$SSCREDS_FILE")")
    fi
    if [ -s "$TGDBKEY_FILE" ]; then
      tgdb_args=(-u "$(cat "$TGDBKEY_FILE")")
    fi

    # Phase 1a: ScreenScraper primary (CRC-exact). --flags unpack hashes the
    # inner ROM inside each zip (No-Intro sets ship zipped); -t 1 honours the
    # free-tier 1-thread cap. Skipped when no creds -> degrades to TGDB below.
    if [ "${#ss_args[@]}" -gt 0 ]; then
      log "$sys: scraping ScreenScraper (primary, CRC-exact, platform=$plat)"
      QT_QPA_PLATFORM=offscreen "$SKY" -p "$plat" -s screenscraper \
        -i "$CART/$sys" -d "$SKCACHE/$plat" -c "$cfg" \
        "${ss_args[@]}" -t 1 --flags unattend,unpack
    else
      log "$sys: WARN no ScreenScraper creds -> TGDB-only (filename-fuzzy, partial)"
    fi

    # Phase 1b: TheGamesDB onlymissing (fills games SS didn't cache). Keyed
    # when available (lifts the per-IP 429). onlymissing guarantees it never
    # overwrites a correct checksum match with a fuzzy filename guess.
    log "$sys: scraping TheGamesDB (secondary, onlymissing)"
    QT_QPA_PLATFORM=offscreen "$SKY" -p "$plat" -s thegamesdb \
      -i "$CART/$sys" -d "$SKCACHE/$plat" -c "$cfg" \
      "${tgdb_args[@]}" --flags unattend,onlymissing

    # Phase 2: compose Pegasus metadata + media from the cache. -d MUST point
    # at the same cache phase-1 wrote to -- without it Skyscraper reads its
    # default ~/.skyscraper/cache/<plat> (empty here) and emits zero game
    # entries, which was the original root cause of the bare metadata files.
    QT_QPA_PLATFORM=offscreen "$SKY" -p "$plat" -f pegasus \
      -i "$CART/$sys" -d "$SKCACHE/$plat" -g "$CART/$sys" -c "$cfg" --flags unattend

    # Skyscraper's pegasus frontend writes ABSOLUTE ROM + media paths rooted at
    # the europa scrape dir (e.g. `file: /tank/.../snes/<rom>`). The kiosks
    # mount this tree read-only at /mnt/europa-cartridges, so those absolute
    # paths don't resolve there and Pegasus silently drops every game + asset
    # ("Game file ... doesn't seem to exist"). Rewrite file:/assets. lines
    # relative to this metadata dir; Pegasus resolves relative paths against
    # the collection root on whichever host mounts it. (Skyscraper exposes no
    # relative-path option for the pegasus frontend -- verified: even `-i .`
    # run from inside the ROM dir still emits absolute paths.)
    sed -i "s|^\(file: \)$CART/$sys/|\1|; s|^\(assets\.[^:]*: \)$CART/$sys/|\1|" \
      "$CART/$sys/metadata.pegasus.txt"
    # Skyscraper also emits whitespace-only lines as intra-description
    # paragraph separators; Pegasus reads those as entry-ending blank lines
    # and then rejects the following indented continuation ("line starts with
    # whitespace, but no attribute has been defined yet"). Drop whitespace-only
    # lines -- truly-empty (0-char) entry separators don't match and survive.
    sed -i '/^[[:space:]][[:space:]]*$/d' "$CART/$sys/metadata.pegasus.txt"

    # Gate ".scraped" on real enrichment: only flag done if game: entries
    # actually landed. A persistent failure (bad creds / broken source) would
    # otherwise stall the serial queue forever, so after 3 zero-game attempts
    # we flag it scraped to advance and log loudly for the operator.
    local games attempts
    games=$(grep -c '^game:' "$CART/$sys/metadata.pegasus.txt" 2>/dev/null || echo 0)
    attempts=$(cat "$STATE/$sys.scrape_attempts" 2>/dev/null || echo 0)
    if [ "${games:-0}" -gt 0 ]; then
      touch "$STATE/$sys.scraped"
      rm -f "$STATE/$sys.scrape_attempts"
      log "$sys: ENRICHED — $games game entries + media written"
    else
      attempts=$((attempts + 1))
      echo "$attempts" > "$STATE/$sys.scrape_attempts"
      if [ "$attempts" -ge 3 ]; then
        touch "$STATE/$sys.scraped"
        log "$sys: GAVE UP after $attempts passes with 0 game entries — flagged scraped to advance the queue; clear $sys.scraped to retry"
      else
        log "$sys: scrape produced 0 game entries (attempt $attempts/3) — will retry next pass"
      fi
    fi
    return 0
  done
  return 1
}

log "=== cartridge-integrate started (pid $$) ==="
while true; do
  # Phase A: promote + launchable minimal metadata for ALL complete systems.
  for entry in "${SYSTEMS[@]}"; do
    promote_if_complete "$entry"
  done
  # Phase B: enrich ONE system with full Skyscraper metadata + art.
  scrape_one || log "nothing to enrich this pass (waiting on downloads)"
  log "pass complete; next pass in 120s"
  sleep 120
done
