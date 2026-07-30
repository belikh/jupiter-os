#!/usr/bin/env bash
# verify-exo-collections.sh — empirical checks for generated eXo Pegasus
# metadata (issue #40 acceptance). Run against collection roots, e.g.:
#   on europa:  ./verify-exo-collections.sh /tank/archive/retro/games/curated/exo-{dos,win3x,win9x}
#   on a kiosk: ./verify-exo-collections.sh /mnt/exo-games/exo-{dos,win3x,win9x}
#
# For each root, checks that metadata.pegasus.txt exists, reports game /
# description / asset-line counts, verifies the launch line is the quoted
# exo-launch form, and resolves a random sample of file:/assets.* paths
# against the collection root (Pegasus resolves relative paths against the
# metadata file's directory). Exits non-zero if any check fails.
#
# (Replaces validate-arcade-metadata.sh / verify-pegasus-artwork.sh, whose
# `((PASS++))` under `set -eu` exited 1 on the first passing check.)
set -eu

SAMPLE=${SAMPLE:-15}
fail=0

check_root() {
    root=$1
    meta="$root/metadata.pegasus.txt"
    echo "== $root"
    if [ ! -f "$meta" ]; then
        echo "   FAIL: no metadata.pegasus.txt"
        fail=1
        return
    fi

    games=$(grep -c '^game: ' "$meta" || true)
    descs=$(grep -c '^description: ' "$meta" || true)
    assets=$(grep -c '^assets\.' "$meta" || true)
    boxfronts=$(grep -c '^assets\.box_front: ' "$meta" || true)
    echo "   games=$games descriptions=$descs asset_lines=$assets box_fronts=$boxfronts"
    [ "$games" -gt 0 ] || { echo "   FAIL: no games"; fail=1; }

    if ! grep -q '^launch: exo-launch \(dosbox\|dosbox-x\) "{file.path}"$' "$meta"; then
        echo "   FAIL: launch line is not the quoted exo-launch form:"
        grep '^launch:' "$meta" | head -2 | sed 's/^/     /'
        fail=1
    fi

    # Sample file: and assets.* paths and stat them relative to the root.
    for key in '^file: ' '^assets\.'; do
        bad=0
        n=0
        while IFS= read -r line; do
            path=${line#*: }
            n=$((n + 1))
            if [ ! -e "$root/$path" ]; then
                bad=$((bad + 1))
                echo "   MISSING ($key): $path"
            fi
        done < <(grep "$key" "$meta" | shuf -n "$SAMPLE" --random-source=<(yes 42) || true)
        if [ "$n" -eq 0 ]; then
            echo "   note: no lines matching $key"
        elif [ "$bad" -gt 0 ]; then
            echo "   FAIL: $bad/$n sampled $key paths do not resolve"
            fail=1
        else
            echo "   ok: $n/$n sampled $key paths resolve"
        fi
    done
}

for root in "$@"; do
    check_root "$root"
done

if [ "$fail" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
