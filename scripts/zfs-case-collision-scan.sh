#!/bin/sh
# zfs-case-collision-scan.sh — pre-flight check for the ZFS
# case-sensitive -> case-insensitive dataset migration
# (see docs/europa-case-insensitive-migration.md).
#
# Scans one or more directory trees for sibling entries (files OR
# directories) whose names collide case-insensitively — e.g. Foo.txt and
# foo.txt sitting in the SAME directory. Two such entries cannot coexist on a
# casesensitivity=insensitive ZFS dataset, so a plain `cp` into one would
# silently overwrite one of them. Every dataset MUST be scanned (and any
# collision resolved by renaming one side) BEFORE the copy step of the
# migration.
#
# Usage:
#   zfs-case-collision-scan.sh <root-dir> [<root-dir> ...]
#   ./zfs-case-collision-scan.sh /tank/archive/retro/games/curated/exo-win9x
#   ./zfs-case-collision-scan.sh /tank/archive/retro/games/curated/exo-{dos,win3x,win9x}
#
# Prints every collision group (colliding names + their absolute paths) to
# stdout and a one-line summary count to stderr. Exit status is 0 when no
# collisions were found and 1 when any were, so it can gate the migration
# (run it as a pre-flight check; abort if it returns non-zero). Exits 2 on
# misuse (no args / a root that is not a directory).
#
# Approach (find + awk, core tools only): walk every entry under each root,
# split each path into parent-dir + basename and lowercase the basename, then
# byte-sort so entries sharing BOTH a parent dir AND a lowercased name become
# adjacent; a final awk pass reports any adjacent run of two-or-more distinct
# names as a collision group. LC_ALL=C forces a deterministic byte ordering
# so the grouping never depends on locale collation. The sort is external, so
# memory cost is bounded regardless of tree size.
set -eu

if [ "$#" -lt 1 ]; then
    echo "usage: $0 <root-dir> [<root-dir> ...]" >&2
    echo "       scans each root for case-insensitive sibling name collisions" >&2
    exit 2
fi

for root in "$@"; do
    if [ ! -d "$root" ]; then
        echo "$0: not a directory: $root" >&2
        exit 2
    fi
done

TAB="$(printf '\t')"

# Stage 1: emit "parent-dir<TAB>lowercased-name<TAB>actual-name<TAB>full-path"
#          per entry (mindepth 1 so the root itself is never a candidate).
# Stage 2: byte-order sort brings identical (parent-dir, lowercased-name)
#          prefixes next to each other.
# Stage 3: walk the sorted stream; any run of >= 2 distinct actual names
#          under the same parent with the same lowercased form is a collision.
LC_ALL=C find "$@" -mindepth 1 | LC_ALL=C awk -v OFS="$TAB" '
    {
        full = $0
        # Split on the LAST "/": everything up to and including it is the
        # parent dir; the rest is the entry name.
        if (match(full, /.*\//)) {
            dir = substr(full, 1, RLENGTH)
            name = substr(full, RLENGTH + 1)
        } else {
            dir = ""
            name = full
        }
        print dir, tolower(name), name, full
    }
' | LC_ALL=C sort | LC_ALL=C awk -F"$TAB" '
    function flush(   i, j, dup) {
        if (n >= 2) {
            # Only a genuine collision if the run holds >= 2 distinct names.
            # (A real filesystem cannot hold two identical exact names in one
            # dir, so two entries sharing a lowercased form is always a real
            # collision — the distinctness guard is just defensive.)
            dup = 0
            for (i = 1; i < n && !dup; i++)
                for (j = i + 1; j <= n; j++)
                    if (names[i] != names[j]) { dup = 1; break }
            if (dup) {
                collisions++
                printf "COLLISION: %d sibling names collide (differ only by case) under:\n", n
                printf "  %s\n", gdir
                for (i = 1; i <= n; i++)
                    printf "    %s  ->  %s\n", names[i], fulls[i]
                printf "\n"
            }
        }
        n = 0
    }
    {
        key = $1 SUBSEP $2
        if (key != prev) {
            flush()
            prev = key
            gdir = $1
        }
        n++
        names[n] = $3
        fulls[n] = $4
    }
    END {
        flush()
        if (collisions) {
            printf "zfs-case-collision-scan: %d collision group(s) found\n", collisions > "/dev/stderr"
            exit 1
        }
        printf "zfs-case-collision-scan: no case collisions found\n" > "/dev/stderr"
    }
'
