#!/bin/sh
# exo-launch: extract-on-first-run + dosbox launcher for the eXo collections.
#
# The eXo layout is tiered: the per-game emulator conf lives at
#   <collection>/eXo/eXoDOS/!dos/<gamedir>/dosbox.conf           (DOS)
#   <collection>/eXo/eXoWin3x/!win3x/<gamedir>/dosbox.conf       (Win3.x)
#   <collection>/eXo/eXoWin9x/!win9x/<year>/<gamedir>/Play.conf  (Win9x)
# while the actual game files stay zipped at
#   <collection>/eXo/eXoDOS/<full name>.zip                      (DOS/Win3.x)
#   <collection>/eXo/eXoWin9x/<year>/<gamedir>.zip               (Win9x)
# until first play. The per-game conf's [autoexec] mounts the game dir
# relative to dosbox's CWD — `.\eXoDOS\<gamedir>` for DOS,
# `.\eXoWin9x\<year>\<gamedir>\<gamedir>.vhd` (a Win98 hard-disk image
# booted with BOOT -l c) for Win9x — which means the emulator's CWD must be
# <collection>/eXo/ (NOT the game dir) when launched, and the zip must have
# been extracted next to its platform dir first.
#
# This wrapper handles both: extract the matching zip on first launch (the
# overlayfs upper in modules/desktop/exodos.nix makes that writable even
# though the underlying NFS mount is read-only), then exec dosbox from the
# right CWD with the per-game conf. Pegasus calls it as
#   exo-launch <dosbox|dosbox-x> <path-to-per-game-conf>
# and we derive everything else from that conf path by convention.
set -eu

EMULATOR="$1"        # dosbox (= dosbox-staging) or dosbox-x
CONF="$2"            # absolute path to the per-game dosbox.conf

if [ -z "$EMULATOR" ] || [ -z "$CONF" ]; then
    echo "usage: exo-launch <dosbox|dosbox-x> <dosbox.conf>" >&2
    exit 2
fi

# eXo's own data is case-inconsistent in places (it was authored on a
# case-insensitive Windows FS): 'Pure-stat College Basketball (1987).bat'
# ships next to 'Pure-Stat College Basketball (1987).zip', and hugo3Jd's zip
# extracts to 'hugo3jd'. On the case-sensitive NFS/overlay these break the
# exact-name lookups below, so resolve names case-insensitively when the
# literal name isn't there. Prints the on-disk name, or nothing.
ci_resolve() {
    ls -A "$1" 2>/dev/null | grep -ixF -- "$2" | head -1
}

# Multi-level case-insensitive resolver: walk $2 (a /-delimited path, with
# optional . and .. components) from ABSOLUTE base dir $1, matching each real
# component case-insensitively against the on-disk entry, and print the fully
# resolved ABSOLUTE path with on-disk casing. On any missing component, print
# $2 unchanged.
#
# The result must be absolute because 86Box resolves a cfg's disk/CD-ROM
# paths relative to the CFG FILE's directory (NOT -P / vmpath, and NOT CWD),
# and we stage the reconciled cfg copy in a scratch dir (/var/lib/exo-overlay/
# 86box-cfg). Relative paths would resolve against that scratch dir and miss
# (verified on amalthea: "unable to load CD-ROM image
# /var/lib/eXoWin9x/1996/Quake (1996)/Winquake.cue"). Absolute paths resolve
# identically no matter where the cfg lives. Also fixes the case mismatch
# (eXo authored these on case-insensitive Windows: cfg says winquake.cue, the
# zip extracts Winquake.cue).
ci_resolve_path() {
    _cur=$1
    _rest=$2
    while [ -n "$_rest" ]; do
        _part=${_rest%%/*}
        if [ "$_rest" = "$_part" ]; then
            _rest=
        else
            _rest=${_rest#*/}
        fi
        [ -z "$_part" ] && continue
        [ "$_part" = "." ] && continue
        if [ "$_part" = ".." ]; then
            _cur=$(dirname "$_cur")
            continue
        fi
        _hit=$(ls -A "$_cur" 2>/dev/null | grep -ixF -- "$_part" | head -1)
        if [ -z "$_hit" ]; then
            printf '%s' "$2"
            return
        fi
        _cur=$_cur/$_hit
    done
    printf '%s' "$_cur"
}

# Rewrite each `FILE "X"` line in a BIN/CUE descriptor ($1) to the on-disk
# case of X, resolved case-insensitively in the .cue's own directory. This is
# the .cue->.bin level of the same Windows case mismatch ci_resolve_path
# fixes at the cfg->.cue level: eXo's .cue files name their .bin tracks in a
# different case than the zip extracts (Quake's Winquake.cue says
# FILE "WINQUAKE.BIN" but the zip extracts Winquake.bin), and 86Box opens
# them case-sensitively, so an unreconciled .cue fails with "Unable to load
# CD-ROM image". Idempotent (only the FILE-name token changes; CRLF→LF) and
# best-effort (never aborts the launch: returns 0 on any internal failure).
# The .cue lives in the extracted game dir (overlay upper, gamer-writable).
fix_cue_refs() {
    _cue=$1
    [ -f "$_cue" ] || return 0
    _cuedir=$(dirname "$_cue")
    : >"$_cue.tmp" || return 0
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            [Ff][Ii][Ll][Ee]\ *)
                _q=${_line#*\"}            # X" BINARY
                _name=${_q%%\"*}           # X
                _tail=${_q#*\"}            # " BINARY (text after closing quote)
                _hit=$(ci_resolve "$_cuedir" "$_name")
                [ -n "$_hit" ] && _name=$_hit
                printf 'FILE "%s"%s\n' "$_name" "$_tail" >>"$_cue.tmp"
                ;;
            *)
                printf '%s\n' "${_line%$'\r'}" >>"$_cue.tmp"
                ;;
        esac
    done <"$_cue"
    mv -f "$_cue.tmp" "$_cue" 2>/dev/null
    return 0
}

GAME_CONFDIR=$(dirname "$CONF")                 # .../!dos/<gamedir>  (or !win3x/<gamedir>, !win9x/<year>/<gamedir>)
GAMEDIR=$(basename "$GAME_CONFDIR")             # <gamedir>, e.g. StuntIsl or "Hyperoid (1994)"
DOS_DIR=$(dirname "$GAME_CONFDIR")              # .../!dos  (or !win3x, or !win9x/<year>)
PLATFORM_DIR=$(basename "$DOS_DIR")             # !dos, !win3x, or a bare <year> under !win9x
GRANDPARENT_DIR=$(basename "$(dirname "$DOS_DIR")")  # !win9x for Win9x games (year level in between)

# Per-platform conventions for where unzipped game files live and where the
# source zip is. eXoDOS and eXoWin3x unzip into <collection>/eXo/<Inner>/
# using the bare <gamedir> as the target subdir; eXoWin9x nests one <year>
# level deeper on both the conf side (!win9x/<year>/<gamedir>) and the
# payload side (eXoWin9x/<year>/<gamedir>.zip).
if [ "$GRANDPARENT_DIR" = "!win9x" ]; then
    PLATFORM_DIR="!win9x"
    YEAR_DIR=$(basename "$DOS_DIR")                     # 1994 / 1995 / 1996
    EXO_COLLECTION_DIR=$(dirname "$(dirname "$DOS_DIR")")  # .../eXo/eXoWin9x
    EXO_DIR=$(dirname "$EXO_COLLECTION_DIR")            # .../eXo
    TARGET="$EXO_COLLECTION_DIR/$YEAR_DIR/$GAMEDIR"     # .../eXo/eXoWin9x/<year>/<gamedir>/
    ZIP_DIR="$EXO_COLLECTION_DIR/$YEAR_DIR"             # .../eXo/eXoWin9x/<year>/<gamedir>.zip
else
    EXO_COLLECTION_DIR=$(dirname "$DOS_DIR")        # .../eXoDOS or .../eXoWin3x (inner)
    EXO_DIR=$(dirname "$EXO_COLLECTION_DIR")        # .../eXo
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
            echo "exo-launch: unexpected platform dir '$PLATFORM_DIR' (expected !dos, !win3x or !win9x/<year>)" >&2
            exit 3
            ;;
    esac
fi

# Extract on first run. For DOS/Win3.x the matching zip is named after the
# game's full title (e.g. "Stunt Island (1992).zip"); the per-game launcher
# .bat in the conf dir is named the same way, so derive the zip name from it
# (install.bat is the only other .bat in these dirs and is excluded). For
# Win9x the game dir, launcher .bat and payload zip all share the same name
# ("Hyperoid (1994)"), so the zip comes straight from $GAMEDIR.
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
# A previous extraction may have created the game dir under the zip's own
# casing rather than the conf dir's (hugo3Jd -> hugo3jd); adopt it so we
# don't re-extract on every launch.
if [ ! -d "$TARGET" ]; then
    ALT=$(ci_resolve "$(dirname "$TARGET")" "$GAMEDIR")
    if [ -n "$ALT" ]; then
        GAMEDIR=$ALT
        TARGET="$(dirname "$TARGET")/$ALT"
    fi
fi

if [ ! -d "$TARGET" ] || [ -z "$(ls -A "$TARGET" 2>/dev/null)" ]; then
    if [ "$PLATFORM_DIR" = "!win9x" ]; then
        ZIP="$ZIP_DIR/$GAMEDIR.zip"
    else
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
    fi
    if [ ! -f "$ZIP" ]; then
        ALT=$(ci_resolve "$ZIP_DIR" "$(basename "$ZIP")")
        [ -n "$ALT" ] && ZIP="$ZIP_DIR/$ALT"
    fi
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

# Install VBMOUSE.DRV for Win3.x games so touch works 1:1 (not relative PS/2).
# dosbox-x natively provides absolute int33 coordinates; VBMOUSE.DRV is the
# Win3.x driver that translates those absolute coordinates for Windows 3.x.
# The per-game image is extracted to $TARGET; we overwrite MOUSE.DRV there
# (idempotent: only if missing or different).
VBMOUSE_DRV=/etc/exo/VBMOUSE.DRV
if [ "$PLATFORM_DIR" = "!win3x" ] && [ -f "$VBMOUSE_DRV" ]; then
    MOUSE_DRV="$TARGET/WINDOWS/SYSTEM/MOUSE.DRV"
    if [ ! -f "$MOUSE_DRV" ] || ! cmp -s "$MOUSE_DRV" "$VBMOUSE_DRV"; then
        cp "$VBMOUSE_DRV" "$MOUSE_DRV"
    fi
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
# --- Win9x: provide a writable C: drive image ------------------------------
# eXoWin9x boots Windows 98 from a hard-disk image that the game's own
# [autoexec] mounts as C: and boots:
#   vhdmake -f -l .\emulators\dosbox\x98\parent/W98-C.vhd .\...\x98\W98-C.vhd
#   IMGMOUNT c .\emulators\dosbox\x98\W98-C.vhd
#   BOOT -l c
# The collection ships that C: image already built, so the vhdmake line is
# belt-and-braces on Windows — and it can't run here anyway: dosbox-x
# 2026.06.02's VHDMAKE aborts with "The parent VHD image ... can't be opened
# for linking" against these images (reproduced against a fully writable
# copy, with both operand orders and both path separators).
#
# What actually breaks Windows is that the shipped image lives on the
# read-only NFS lower, so booting it gives "General failure writing drive C"
# the moment Windows touches the registry or swap. overlayfs won't let the
# session user fix that in place either: it denies *creates* in directories
# that exist on the lower even when the upper copy of the directory is owned
# by them (only writes to files already in the upper succeed — the same
# ovl_permission behaviour that forces extraction through the root helper).
#
# So the root helper materialises C: in the overlay upper, owned by the
# session user. It does that on EVERY launch, restoring a pristine image
# from a local master — which is exactly what eXo's own `vhdmake -f` line
# achieves by rebuilding the child each time. That matters because C: is a
# disposable boot volume SHARED by ~621 titles: persisting it would let one
# game's registry writes, driver installs or a mid-write crash follow every
# other game. Per-game state lives on D: — the game's own VHD, which does
# persist in the overlay upper. The reset is effectively free: master and
# upper sit on the same ZFS dataset, so it's a block clone (0.16s/396 MB).
if [ "$PLATFORM_DIR" = "!win9x" ]; then
    # The conf names the image; don't hardcode W98-C.vhd (a handful of games
    # boot W98-J/W98-H/W95-C instead).
    # eXo's confs are CRLF and space-padded to a fixed width, so strip the CR
    # and any trailing blanks before using the value as a path — otherwise
    # every -f test below silently fails and C: is never prepared.
    CHILD_REL=$(sed -n 's/\r//g; s/^[Ii][Mm][Gg][Mm][Oo][Uu][Nn][Tt][[:space:]][[:space:]]*[Cc][[:space:]][[:space:]]*//p' "$CONF" \
        | head -1 | sed 's/[[:space:]]*$//; s/^"//; s/"[[:space:]]*$//; s/^\.\\//; s/\\/\//g')
    if [ -n "$CHILD_REL" ]; then
        CHILD="$EXO_DIR/$CHILD_REL"
        # Source the BASE image under parent/, not the sibling image the
        # collection ships at the mount path: that one is a *differencing*
        # VHD (footer disk type 4) whose parent link dosbox-x does not
        # resolve here — booting it gives "Invalid system disk" (verified on
        # amalthea). The parent/ image is a self-contained dynamic VHD and
        # boots. Fall back to the shipped image only if a collection ships
        # no parent/ copy at all.
        SRC="$(dirname "$CHILD")/parent/$(basename "$CHILD")"
        [ -f "$SRC" ] || SRC="$CHILD"
        if [ -f "$SRC" ]; then
            SUDO=/run/wrappers/bin/sudo
            HELPER=$(readlink -f "$(command -v exo-prepare-c-drive)") || {
                echo "exo-launch: exo-prepare-c-drive not on PATH" >&2
                exit 8
            }
            "$SUDO" -n "$HELPER" "$SRC" "$CHILD" "$(id -un)" "$(id -gn)"
        fi
    fi
fi

# --- 86Box titles (eXoWin9x subset) ----------------------------------------
# The 30 eXoWin9x titles that ship an 86Box Play.cfg reach this branch via
# `exo-launch 86box <Play.cfg>`. Everything above (path derivation, the
# !win9x first-run extraction) is identical to the dosbox-x Win9x path and
# already got the game's own .vhd/.cue extracted into the overlay upper.
#
# Two things make 86Box simpler than dosbox-x here:
#   1. Every 86Box Play.cfg sets hdd_*_speed = ramdisk, so 86Box loads each
#      VHD into memory and writes go to RAM, never to the image file. The
#      shared W98-C.vhd boot disk stays pristine on the read-only NFS lower,
#      so — unlike dosbox-x above — there is no writable-C: image to
#      materialise and no exo-prepare-c-drive call.
#   2. The bundled 86Box98/ dir is the VM root eXo authored everything
#      against (../../eXoWin9x/<year>/<game>/... for the game disk, sibling
#      roms/ for BIOS files, sibling nvr/ for CMOS), so -P MUST point at it
#      through the merge mount. CAVEAT: 86Box resolves a cfg's *relative*
#      disk/CD-ROM paths against the cfg FILE's directory, NOT -P (verified
#      on amalthea — a relative path resolved against the scratch dir and
#      missed). Because we stage the cfg copy in a scratch dir, the rewrite
#      below emits ABSOLUTE paths (ci_resolve_path), which resolve
#      identically wherever the cfg lives. -P still matters for roms/ + nvr/.
#
# 86Box also writes its config back to the file it was handed on exit; the
# per-game Play.cfg lives on the read-only NFS lower, so stage a fresh copy
# in a per-kiosk writable scratch dir (with each disk/CD-ROM path rewritten
# to absolute + on-disk case) and hand 86Box that. The copy is recreated
# every launch (cheap; a Play.cfg is ~1.7 KB) so one game's exit state can't
# leak into the next. SCRATCH tracks jupiter.exodos.overlayBase's default
# (/var/lib/exo-overlay); the module owns and gamer-owns this dir.
if [ "$EMULATOR" = "86box" ]; then
    VMPATH="$EXO_DIR/emulators/86Box98"
    if [ ! -d "$VMPATH" ]; then
        echo "exo-launch: 86Box VM path not found: $VMPATH" >&2
        exit 9
    fi
    SCRATCH=/var/lib/exo-overlay/86box-cfg
    WRITABLE_CFG="$CONF"
    CUES=
    if [ -d "$SCRATCH" ]; then
        OUT="$SCRATCH/$GAMEDIR.cfg"
        : >"$OUT.tmp"
        # Rewrite each disk/CD-ROM image path in the staged copy to an
        # ABSOLUTE, case-corrected path (see ci_resolve_path). Absolute
        # because 86Box resolves cfg paths against the cfg file's dir (not
        # -P), and this copy lives in the scratch dir. eXo's Play.cfg files
        # were authored on case-insensitive Windows and routinely disagree
        # with the extracted filename case (Quake's cfg says winquake.cue,
        # the zip extracts Winquake.cue); 86Box on Linux opens these
        # case-sensitively, so without this every CD-ROM game fails to find
        # its disc. Other lines pass through verbatim (CRLF stripped to LF,
        # which 86Box's ini parser reads fine).
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                hdd_*_fn*=* | cdrom_*_image_path*=*)
                    key=${line%%=*}
                    key=${key%"${key##*[![:space:]]}"}
                    val=${line#*=}
                    val=${val%$'\r'}
                    val=${val%"${val##*[![:space:]]}"}
                    val=${val#"${val%%[![:space:]]*}"}
                    case "$key" in
                        hdd_01_fn*)
                            # C: boot disk. eXo ships an EMPTY *-C.vhd stub
                            # that its Windows launcher deletes + rebuilds as
                            # a child of parent/*-P.vhd via makevhd.exe at
                            # launch (see 9xlaunch86Box.bat). We can't run
                            # makevhd, and we don't need to: every 86Box cfg
                            # sets hdd_*_speed = ramdisk, so 86Box loads the
                            # VHD read-only into RAM. Point hdd_01 straight
                            # at the parent image — same bootable content as
                            # a fresh child (parent + empty delta), and the
                            # read-only NFS lower is fine for a ramdisk load.
                            cbase=$(ci_resolve_path "$VMPATH" "$val")
                            cdir=$(dirname "$cbase")
                            pbn=$(basename "$cbase"); pbn=${pbn%-C.vhd}
                            parent=$(ci_resolve_path "$cdir/parent" "${pbn}-P.vhd")
                            if [ -f "$parent" ]; then
                                fixed=$parent
                            else
                                fixed=$cbase
                            fi
                            ;;
                        *)
                            fixed=$(ci_resolve_path "$VMPATH" "$val")
                            ;;
                    esac
                    printf '%s = %s\n' "$key" "$fixed" >>"$OUT.tmp"
                    # Collect cdrom image paths so we can reconcile the
                    # .cue's internal FILE->bin refs too (one case level
                    # deeper — see fix_cue_refs).
                    case "$key" in
                        cdrom_*_image_path*) CUES="${CUES:+$CUES
}$fixed" ;;
                    esac
                    ;;
                *)
                    printf '%s\n' "${line%$'\r'}" >>"$OUT.tmp"
                    ;;
            esac
        done <"$CONF"
        if mv -f "$OUT.tmp" "$OUT" 2>/dev/null; then
            WRITABLE_CFG="$OUT"
        else
            echo "exo-launch: 86Box cfg staging failed (using read-only $CONF)" >&2
        fi
        # Reconcile each referenced .cue's FILE->bin names to on-disk case.
        # The .cue is in the extracted game dir (gamer-writable); fix_cue_refs
        # is idempotent and best-effort.
        if [ -n "$CUES" ]; then
            printf '%s\n' "$CUES" | while IFS= read -r _c; do
                [ -n "$_c" ] || continue
                case "$_c" in
                    *.[Cc][Uu][Ee]) fix_cue_refs "$_c" ;;
                esac
            done
        fi
    fi
    # nixpkgs _86box installs the binary as `86Box` (capital B); the launch
    # line from Pegasus passes the lowercase `86box` token, which we use only
    # to branch above. -F fullscreen, -N no confirm-on-quit, -P VM root,
    # -R ROM dir, then the staged per-game cfg.
    exec env PULSE_SINK=bluez_output.D8_E3_5E_8A_72_E5.1 86Box \
        -F -N -P "$VMPATH" -R "$VMPATH/roms" "$WRITABLE_CFG"
fi

set -- -conf "$CONF"
# eXoWin9x ships a platform-wide options conf that the original Windows
# launcher (util/9xlaunch.bat) always passes after the per-game Play.conf —
# shared dosbox-x defaults for the Win98-VHD boot flow. Same ordering here.
if [ "$PLATFORM_DIR" = "!win9x" ] && [ -f "$EXO_DIR/emulators/dosbox/options9x.conf" ]; then
    set -- "$@" -conf "$EXO_DIR/emulators/dosbox/options9x.conf"
fi
if [ -n "$OVERRIDE" ] && [ -f "$OVERRIDE" ]; then
    set -- "$@" -conf "$OVERRIDE"
fi
exec env PULSE_SINK=bluez_output.D8_E3_5E_8A_72_E5.1 "$EMULATOR" "$@" -noconsole -c exit
