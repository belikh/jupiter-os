#!/bin/sh
# exo-launch: extract-on-first-run + dosbox launcher for the eXo collections.
#
# The eXoDOS / eXoWin3x layout is tiered: the per-game dosbox.conf lives at
#   <collection>/eXo/eXoDOS/!dos/<gamedir>/dosbox.conf      (DOS)
#   <collection>/eXo/eXoWin3x/!win3x/<gamedir>/dosbox.conf   (Win3.x)
# while the actual game files stay zipped at
#   <collection>/eXo/eXoDOS/<full name>.zip
# until first play. The per-game dosbox.conf's [autoexec] mounts C: at
# `.\eXoDOS\<gamedir>` and runs the game's run.bat from there, which means
# dosbox's CWD must be <collection>/eXo/ (NOT the game dir) when launched,
# and the zip must have been extracted into <collection>/eXo/eXoDOS/<gamedir>/.
#
# This wrapper handles both: extract the matching zip on first launch (the
# overlayfs upper in modules/desktop/exodos.nix makes that writable even
# though the underlying NFS mount is read-only), then exec dosbox from the
# right CWD with the per-game conf. Pegasus calls it as
#   exo-launch <dosbox|dosbox-x> <path-to-per-game-dosbox.conf>
# and we derive everything else from that conf path by convention.
set -eu

EMULATOR="$1"        # dosbox (= dosbox-staging) or dosbox-x
CONF="$2"            # absolute path to the per-game dosbox.conf

if [ -z "$EMULATOR" ] || [ -z "$CONF" ]; then
    echo "usage: exo-launch <dosbox|dosbox-x> <dosbox.conf>" >&2
    exit 2
fi

GAME_CONFDIR=$(dirname "$CONF")                 # .../!dos/<gamedir>  (or !win3x/<gamedir>)
GAMEDIR=$(basename "$GAME_CONFDIR")             # <gamedir>, e.g. StuntIsl
DOS_DIR=$(dirname "$GAME_CONFDIR")              # .../!dos            (or !win3x)
PLATFORM_DIR=$(basename "$DOS_DIR")             # !dos or !win3x
EXO_COLLECTION_DIR=$(dirname "$DOS_DIR")        # .../eXoDOS or .../eXoWin3x (inner)
EXO_DIR=$(dirname "$EXO_COLLECTION_DIR")        # .../eXo

# Per-platform conventions for where unzipped game files live and where the
# source zip is. eXoDOS and eXoWin3x both unzip into <collection>/eXo/<Inner>/
# using the bare <gamedir> as the target subdir.
case "$PLATFORM_DIR" in
    "!dos")
        TARGET="$EXO_COLLECTION_DIR/$GAMEDIR"           # .../eXo/eXoDOS/<gamedir>/
        ZIP_DIR="$EXO_COLLECTION_DIR"                   # .../eXo/eXoDOS/<FullName>.zip
        ;;
    "!win3x")
        TARGET="$EXO_COLLECTION_DIR/$GAMEDIR"           # .../eXo/eXoWin3x/<gamedir>/
        ZIP_DIR="$EXO_COLLECTION_DIR"                   # .../eXo/eXoWin3x/<FullName>.zip
        ;;
    *)
        echo "exo-launch: unexpected platform dir '$PLATFORM_DIR' (expected !dos or !win3x)" >&2
        exit 3
        ;;
esac

# Extract on first run. The matching zip is named after the game's full title
# (e.g. "Stunt Island (1992).zip"); the per-game launcher .bat in the conf dir
# is named the same way, so derive the zip name from it. install.bat is the
# only other .bat in these dirs and is excluded.
if [ ! -d "$TARGET" ]; then
    BAT=$(
        cd "$GAME_CONFDIR" || exit 4
        for f in *.bat; do
            [ "$f" = "install.bat" ] && continue
            [ "$f" = "*.bat" ] && continue
            echo "$f"
            break
        done
    )
    if [ -z "$BAT" ]; then
        echo "exo-launch: no launcher .bat found in $GAME_CONFDIR" >&2
        exit 5
    fi
    FULL_NAME=${BAT%.bat}
    ZIP="$ZIP_DIR/$FULL_NAME.zip"
    if [ ! -f "$ZIP" ]; then
        echo "exo-launch: game zip not found at $ZIP" >&2
        exit 6
    fi
    # unzip creates <gamedir>/ inside ZIP_DIR (the zip's top-level entry).
    # Use -o so re-runs after a partial extract don't prompt. -q for quiet.
    if ! command -v unzip >/dev/null 2>&1; then
        echo "exo-launch: unzip not on PATH" >&2
        exit 7
    fi
    unzip -q -o "$ZIP" -d "$ZIP_DIR"
fi

# dosbox's CWD must be eXo/ so the per-game conf's relative mounts/paths
# (.\eXoDOS\<gamedir>, .\mt32, .\dosbox\..., etc.) resolve the way eXo's
# original Windows launcher set them up.
cd "$EXO_DIR"
exec "$EMULATOR" -conf "$CONF" -noconsole -c exit
