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
#
# Existence check is "dir exists AND is non-empty" — a plain `[ ! -d ]` gets
# fooled by stale overlay dentries: an interrupted extraction (or a dosbox
# mount that created the target) leaves an empty dir that the kernel's dentry
# cache keeps reporting as existing forever, so dosbox-x runs into nothing.
# Re-extracting when the dir is empty is harmless (unzip -o overwrites) and
# recovers the kiosk from any half-extracted state without a reboot.
#
# Extraction runs via `sudo -n exo-extract-helper` (installed by
# modules/desktop/exodos.nix with a NOPASSWD sudoers rule). overlayfs's
# ovl_permission checks write on BOTH upper and lower for creates in dirs that
# exist in both layers; the NFS lower's mode bits are inconsistent and europa
# is import-level read-only, so a non-root unzip dies with EACCES. The helper
# unzips as root then chowns the result back to the calling user, so dosbox
# (running as that user) can later write saves into the per-game dir — by then
# in the upper only, so no further lower-perm check.
if [ ! -d "$TARGET" ] || [ -z "$(ls -A "$TARGET" 2>/dev/null)" ]; then
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
    # Use the NixOS setuid sudo wrapper directly. The session's PATH (set by
    # dashboard-gaming.nix's mkLauncher) puts /run/current-system/sw/bin first,
    # where the NON-setuid Nix-store sudo lives — that one refuses to run with
    # "must be owned by uid 0 and have the setuid bit set". /run/wrappers/bin
    # is the canonical location for setuid wrappers on NixOS.
    SUDO=/run/wrappers/bin/sudo
    [ -x "$SUDO" ] || {
        echo "exo-launch: $SUDO not executable" >&2
        exit 7
    }
    # Resolve the helper's full canonical path so sudo can match it against
    # the NOPASSWD rule (which is keyed on the absolute Nix-store path; sudo
    # does NOT resolve the /run/current-system/sw/bin symlink itself).
    HELPER=$(readlink -f "$(command -v exo-extract-helper)") || {
        echo "exo-launch: exo-extract-helper not on PATH" >&2
        exit 7
    }
    CALLING_USER=$(id -un)
    CALLING_GROUP=$(id -gn)
    # -n: non-interactive (fail if a password would be needed)
    "$SUDO" -n "$HELPER" "$ZIP" "$ZIP_DIR" "$GAMEDIR" "$CALLING_USER" "$CALLING_GROUP"
fi

# dosbox's CWD must be eXo/ so the per-game conf's relative mounts/paths
# (.\eXoDOS\<gamedir>, .\mt32, .\dosbox\..., etc.) resolve the way eXo's
# original Windows launcher set them up.
cd "$EXO_DIR"
# Pass our kiosk override conf AFTER the per-game conf so our settings win.
# dosbox-staging and dosbox-x both honor multiple -conf flags in order. The
# override forces fullscreen at the panel's native 1024x768 (which hides
# dosbox-x's menu bar — without it, the menu bar eats vertical space and the
# 1024x768 game gets squeezed into the remaining area with ugly scaling), and
# for dosbox-x (Win3.x) also tries integration-mode mouse for absolute touch.
case "$EMULATOR" in
    dosbox-x)
        OVERRIDE=/etc/exo/dosbox-x-override.conf
        ;;
    dosbox)
        OVERRIDE=/etc/exo/dosbox-override.conf
        ;;
    *)
        OVERRIDE=
        ;;
esac
if [ -n "$OVERRIDE" ] && [ -f "$OVERRIDE" ]; then
    exec "$EMULATOR" -conf "$CONF" -conf "$OVERRIDE" -noconsole -c exit
else
    exec "$EMULATOR" -conf "$CONF" -noconsole -c exit
fi
