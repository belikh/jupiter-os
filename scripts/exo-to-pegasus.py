#!/usr/bin/env python3
"""LaunchBox XML -> Pegasus metadata converter for the eXo collections.

Reads a LaunchBox <Game> XML (eXoDOS's xml/MS-DOS.xml, eXoWin3x's
xml/Windows 3x.xml, eXoWin9x's xml/Windows 9x.xml), emits a Pegasus
metadata.pegasus.txt at the collection root. Each game's `file:` points at
its per-game emulator conf (relative to the collection root); the
collection-level `launch` invokes exo-launch (modules/desktop/exodos.nix)
with that conf, which extracts the game zip on first run and execs
dosbox-staging (DOS), or dosbox-x (Win3.x / Win9x) from the right CWD so
each eXo conf's [autoexec] (relative mounts, .bat launcher) works
unmodified.

Artwork: the eXo LaunchBox XMLs carry NO per-game image paths (only
Missing*Image booleans — verified empirically against eXoDOS v5 /
eXoWin3x v2 / eXoWin9x v1), so images are matched by TITLE against the
collection's Images/<Platform>/<Type>/ tree using LaunchBox's filename
convention: every character in  \\ / : * ? " < > | '  becomes '_', a -NN
index suffix is appended (not always starting at -01), and files sit
either at the type-dir root or one region subdir deep (United States,
World, ...). Asset lines are emitted as `assets.<type>:` keys — the only
form Pegasus parses (rx `^assets?\\.(.+)$` in PegasusMetadata.cpp); bare
`screenshot:`/`image:` keys are silently ignored by Pegasus.

Idempotent: skips writing when the existing output is newer than the
source XML unless --force is passed. Run by jupiter-exodos-metadata.service
(modules/desktop/exodos.nix) on every entry into the arcade session.

Pegasus metadata syntax: https://pegasus-frontend.org/docs/user-guide/meta-files/
"""
import argparse
import os
import re
import sys
import xml.etree.ElementTree as ET

# Pegasus asset key -> LaunchBox Images/<Platform>/ type directory.
# Keys are from Pegasus's PegasusAssets.cpp str_to_type map; dirs are the
# LaunchBox names present in all three eXo collections (missing dirs are
# skipped per-collection).
ASSET_TYPE_DIRS = [
    ("box_front", "Box - Front"),
    ("screenshot", "Screenshot - Gameplay"),
    ("titlescreen", "Screenshot - Game Title"),
    ("logo", "Clear Logo"),
    ("background", "Fanart - Background"),
]

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".gif"}

# LaunchBox replaces each of these characters with '_' when deriving image
# filenames from titles (verified empirically: "Amy's First Primer" ->
# "Amy_s First Primer-01.jpg", "Vamp 1/2" -> "Vamp 1_2-01.jpg", "Traders:
# The ..." -> "Traders_ The ...-01.jpg"). The set is the Windows-invalid
# filename chars plus the apostrophe.
_SANITIZE_RX = re.compile(r"[\\/:*?\"<>|']")

# Region subdirectories are ranked so the "canonical" art wins when a title
# has copies in several regions; files at the type-dir root rank first.
_REGION_RANK = {"": 0, "United States": 1, "World": 2, "North America": 3}

# Image stems carry an optional -NN (occasionally -NNN) index suffix.
_STEM_RX = re.compile(r"^(?P<base>.*?)(?:-(?P<idx>\d{1,3}))?$")


def sanitize_title(title: str) -> str:
    return _SANITIZE_RX.sub("_", title)


def build_image_index(images_dir: str, root: str) -> dict:
    """Map asset key -> {sanitized title -> collection-root-relative path}.

    For each mapped LaunchBox type dir, walk it fully (region subdirs are one
    level deep in practice, but a full walk costs nothing and survives layout
    surprises) and keep, per title, the best candidate by (region rank, index
    suffix, path) so results are deterministic.
    """
    index = {}
    for asset_key, type_name in ASSET_TYPE_DIRS:
        type_dir = os.path.join(images_dir, type_name)
        if not os.path.isdir(type_dir):
            continue
        best = {}
        for dirpath, _dirnames, filenames in os.walk(type_dir):
            region = os.path.relpath(dirpath, type_dir)
            if region == ".":
                region = ""
            rank = _REGION_RANK.get(region, 4)
            for fname in filenames:
                stem, ext = os.path.splitext(fname)
                if ext.lower() not in IMAGE_EXTS:
                    continue
                m = _STEM_RX.match(stem)
                base = m.group("base")
                idx = int(m.group("idx")) if m.group("idx") else 0
                rel = os.path.relpath(os.path.join(dirpath, fname), root)
                cand = (rank, idx, rel)
                if base not in best or cand < best[base]:
                    best[base] = cand
        index[asset_key] = {base: cand[2] for base, cand in best.items()}
    return index


class CasePathResolver:
    """Resolve a relative path against the collection root case-insensitively.

    The LaunchBox XMLs were written on a case-insensitive Windows FS and get
    the on-disk casing wrong in two ways: systematically (eXoWin3X vs
    eXoWin3x — fixable with --rewrite) and per-game (ultima1 vs Ultima1,
    calcman vs Calcman: 38 eXoDOS games — not enumerable). ZFS here is
    casesensitivity=sensitive, so we resolve each component against a cached
    directory listing and rewrite it to the on-disk casing.
    """

    def __init__(self, root: str):
        self.root = root
        self._cache = {}

    def _listing(self, abs_dir: str) -> dict:
        if abs_dir not in self._cache:
            try:
                self._cache[abs_dir] = {n.lower(): n for n in os.listdir(abs_dir)}
            except OSError:
                self._cache[abs_dir] = {}
        return self._cache[abs_dir]

    def resolve(self, rel_path: str):
        """Return rel_path with on-disk casing, or None if any part is absent."""
        cur = self.root
        out = []
        for part in rel_path.split("/"):
            hit = self._listing(cur).get(part.lower())
            if hit is None:
                return None
            out.append(hit)
            cur = os.path.join(cur, hit)
        return "/".join(out)


def game_dir_from_application_path(application_path: str, rewrites: list) -> str:
    # LaunchBox stores Windows-style paths (eXo\eXoDOS\!dos\StuntIsl\foo.bat);
    # Pegasus wants POSIX paths, and we anchor on the game's directory so the
    # per-game conf (sibling of the .bat launcher) resolves.
    posix_path = application_path.replace("\\", "/")
    # LaunchBox ran on Windows (case-insensitive FS), so its stored paths don't
    # always match the on-disk case of the eXo collection as extracted on a
    # case-sensitive Linux FS. eXoWin3x is the worst offender: 1062 of 1139
    # games say eXoWin3X while the extracted dir is eXoWin3x (and ZFS is
    # casesensitivity=sensitive). Each --rewrite OLD:NEW applies a literal
    # substring replacement before we dirname().
    for old, new in rewrites:
        posix_path = posix_path.replace(old, new)
    return os.path.dirname(posix_path)


def text_or_empty(parent: ET.Element, tag: str) -> str:
    el = parent.find(tag)
    if el is None or el.text is None:
        return ""
    return el.text.strip()


def bool_field(parent: ET.Element, tag: str) -> bool:
    return text_or_empty(parent, tag).lower() == "true"


def release_date(date_str: str) -> str:
    # LaunchBox stores full ISO (1992-01-01T00:00:00-06:00); Pegasus accepts
    # YYYY-MM-DD. Take the date prefix; if absent, fall back to nothing.
    if not date_str:
        return ""
    return date_str[:10]


def community_rating(star_str: str) -> str:
    # LaunchBox CommunityStarRating is 0..5; Pegasus rating is 0..100%.
    try:
        stars = float(star_str)
    except (TypeError, ValueError):
        return ""
    if stars <= 0:
        return ""
    return f"{round(stars * 20)}%"


def collapse_ws(text: str) -> str:
    # Pegasus descriptions are logical lines; flatten internal newlines and
    # runs of whitespace so a stray \n in LaunchBox's <Notes> can't terminate
    # the entry early.
    return " ".join(text.split())


def split_list(field: str) -> list:
    # LaunchBox uses ';' as the separator (e.g. "Cards / Tiles;Puzzle;Sports"
    # for Genre, "Single Player;Multiplayer" for PlayMode).
    if not field:
        return []
    return [g.strip() for g in field.split(";") if g.strip()]


def escape_value(value: str) -> str:
    # Pegasus values run to end-of-line; strip a leading space so "key: value"
    # never becomes "key:  value" (which would make the value start with a
    # space, parsed as a list-item continuation). Internal colons are fine.
    return value.lstrip()


def render_entry(
    title: str,
    file_rel: str,
    developer: str,
    publisher: str,
    genres: list,
    tags: list,
    release: str,
    description: str,
    rating: str,
    favorite: bool,
    lb_id: str,
    manual_rel: str,
    assets: dict,
) -> list:
    lines = [f"game: {escape_value(title)}"]
    lines.append(f"file: {file_rel}")
    if developer:
        lines.append(f"developer: {escape_value(developer)}")
    if publisher:
        lines.append(f"publisher: {escape_value(publisher)}")
    for g in genres:
        lines.append(f"genre: {escape_value(g)}")
    for t in tags:
        lines.append(f"tag: {escape_value(t)}")
    if release:
        lines.append(f"release: {release}")
    if description:
        lines.append(f"description: {escape_value(description)}")
    if rating:
        lines.append(f"rating: {rating}")
    for asset_key, rel in assets.items():
        lines.append(f"assets.{asset_key}: {escape_value(rel)}")
    if favorite:
        lines.append("x-favorite: true")
    if lb_id:
        lines.append(f"x-lb-id: {lb_id}")
    if manual_rel:
        lines.append(f"x-manual: {escape_value(manual_rel)}")
    lines.append("")  # blank separator between entries
    return lines


def convert(
    xml_path: str,
    root: str,
    collection: str,
    shortname: str,
    emulator: str,
    conf_name: str,
    images_platform: str,
    rewrites: list,
    check_files: bool,
):
    tree = ET.parse(xml_path)
    root_el = tree.getroot()

    # Derive the Images/<Platform> dir from the XML when not given explicitly
    # (the <Platform> field matches the on-disk platform dir name in all three
    # eXo collections: MS-DOS, Windows 3x, Windows 9x).
    if not images_platform:
        for game in root_el.findall("Game"):
            images_platform = text_or_empty(game, "Platform")
            if images_platform:
                break

    images_dir = os.path.join(root, "Images", images_platform)
    image_index = build_image_index(images_dir, root) if os.path.isdir(images_dir) else {}

    out_lines = [
        f"# Generated by scripts/exo-to-pegasus.py from {os.path.basename(xml_path)}.",
        "# Do not edit by hand — regenerate via jupiter-exodos-metadata.service.",
        f"# Collection root: {root}",
        f"# Emulator: {emulator}",
        "",
        f"collection: {collection}",
        f"shortname: {shortname}",
        # The eXo launch flow: each game's conf [autoexec] mounts its game dir
        # relative to dosbox's CWD (the collection's eXo/ dir, NOT the game
        # dir), so the bundled game files must be unzipped next to it first.
        # `exo-launch` (modules/desktop/exodos.nix) takes the per-game conf
        # path, extracts the matching zip on first run (into the persisted
        # overlay upper), then execs the emulator from the right CWD.
        # {file.path} is quoted because Pegasus tokenizes the launch line on
        # whitespace BEFORE substituting fields (CommandTokenizer.cpp) and
        # every eXo path contains spaces.
        f'launch: exo-launch {emulator} "{{file.path}}"',
        "",
    ]

    counts = {"emitted": 0, "hidden": 0, "no_path": 0, "no_conf": 0, "case_fixed": 0}
    asset_lines = 0
    described = 0
    resolver = CasePathResolver(root)

    for game in root_el.findall("Game"):
        if bool_field(game, "Hide") or bool_field(game, "Broken"):
            counts["hidden"] += 1
            continue

        application_path = text_or_empty(game, "ApplicationPath")
        if not application_path:
            # Each eXo platform XML carries one dummy <Game> named after the
            # platform itself with an empty ApplicationPath — skip it.
            counts["no_path"] += 1
            continue

        title = text_or_empty(game, "Title") or "(untitled)"
        game_dir = game_dir_from_application_path(application_path, rewrites)
        # The per-game conf is the launch anchor: it carries the cycles/cpu/
        # sound/autoexec settings eXo tuned per title. Games without one on
        # disk (eXoWin9x's 29 86Box-only titles have Play.cfg, not Play.conf;
        # one win3x XML entry has no game dir at all) are skipped so the
        # launcher never gets a dead path.
        file_rel = f"{game_dir}/{conf_name}" if game_dir else conf_name
        if check_files and not os.path.isfile(os.path.join(root, file_rel)):
            resolved = resolver.resolve(file_rel)
            if resolved is None:
                counts["no_conf"] += 1
                continue
            file_rel = resolved
            counts["case_fixed"] += 1

        # Artwork lookup keys, in priority order. eXoDOS/eXoWin3x name their
        # images after the sanitized TITLE (+ a -NN index); eXoWin9x names
        # them after the GAME DIRECTORY ("Final DOOM (1996).png", ":" already
        # rendered as " - "). The dir key goes first because it is unique per
        # game, so same-titled games (eXoWin9x ships two "Mastermind"s) get
        # their own art instead of aliasing to one image.
        lookup_keys = [
            sanitize_title(os.path.basename(game_dir)),
            sanitize_title(title),
        ]
        assets = {}
        for asset_key, _type_name in ASSET_TYPE_DIRS:
            by_key = image_index.get(asset_key, {})
            for k in lookup_keys:
                rel = by_key.get(k)
                if rel:
                    assets[asset_key] = rel
                    break
        asset_lines += len(assets)

        manual_rel = text_or_empty(game, "ManualPath").replace("\\", "/")
        if manual_rel and check_files and not os.path.isfile(os.path.join(root, manual_rel)):
            manual_rel = resolver.resolve(manual_rel) or ""

        description = collapse_ws(text_or_empty(game, "Notes"))
        if description:
            described += 1

        out_lines.extend(
            render_entry(
                title=title,
                file_rel=file_rel,
                developer=text_or_empty(game, "Developer"),
                publisher=text_or_empty(game, "Publisher"),
                genres=split_list(text_or_empty(game, "Genre")),
                tags=split_list(text_or_empty(game, "PlayMode")),
                release=release_date(text_or_empty(game, "ReleaseDate")),
                description=description,
                rating=community_rating(text_or_empty(game, "CommunityStarRating")),
                favorite=bool_field(game, "Favorite"),
                lb_id=text_or_empty(game, "ID"),
                manual_rel=manual_rel,
                assets=assets,
            )
        )
        counts["emitted"] += 1

    return out_lines, counts, asset_lines, described


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--xml", required=True, help="Path to the LaunchBox platform XML")
    p.add_argument("--root", required=True, help="Collection root (metadata.pegasus.txt lives here)")
    p.add_argument("--collection", required=True, help="Pegasus collection name, e.g. 'eXoDOS'")
    p.add_argument("--shortname", required=True, help="Pegasus shortname, e.g. 'dos' or 'win3x'")
    p.add_argument(
        "--emulator",
        required=True,
        choices=["dosbox", "dosbox-x"],
        help="Binary name (dosbox=dosbox-staging, dosbox-x=dosbox-x)",
    )
    p.add_argument(
        "--conf-name",
        default="dosbox.conf",
        help="Per-game conf filename: dosbox.conf (eXoDOS/eXoWin3x) or Play.conf (eXoWin9x)",
    )
    p.add_argument(
        "--images-platform",
        default="",
        help="Subdir of Images/ holding this platform's art (default: the XML's <Platform> field)",
    )
    p.add_argument(
        "--rewrite",
        action="append",
        default=[],
        metavar="OLD:NEW",
        help=(
            "Literal substring rewrite applied to each game's POSIX-converted "
            "ApplicationPath (repeatable). Use to fix Windows-vs-Linux case "
            "mismatches, e.g. --rewrite eXoWin3X:eXoWin3x"
        ),
    )
    p.add_argument(
        "--no-check-files",
        action="store_true",
        help="Skip on-disk existence checks for file:/x-manual (for generating outside the collection)",
    )
    p.add_argument("--force", action="store_true", help="Regenerate even if output is newer than XML")
    args = p.parse_args()

    rewrites = [tuple(r.split(":", 1)) for r in args.rewrite]
    if any(len(r) != 2 for r in rewrites):
        p.error("--rewrite values must be OLD:NEW (got one without a colon)")

    output_path = os.path.join(args.root, "metadata.pegasus.txt")

    if not args.force and os.path.exists(output_path):
        xml_mtime = os.path.getmtime(args.xml)
        out_mtime = os.path.getmtime(output_path)
        if out_mtime >= xml_mtime:
            print(
                f"skip: {output_path} is newer than {args.xml} (use --force to regenerate)",
                file=sys.stderr,
            )
            return 0

    out_lines, counts, asset_lines, described = convert(
        xml_path=args.xml,
        root=args.root,
        collection=args.collection,
        shortname=args.shortname,
        emulator=args.emulator,
        conf_name=args.conf_name,
        images_platform=args.images_platform,
        rewrites=rewrites,
        check_files=not args.no_check_files,
    )

    os.makedirs(args.root, exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        f.write("\n".join(out_lines))

    print(
        f"wrote {output_path}: {counts['emitted']} games emitted "
        f"({described} with descriptions, {asset_lines} asset lines, "
        f"{counts['case_fixed']} paths case-corrected), "
        f"{counts['hidden']} hidden/broken skipped, {counts['no_path']} pathless skipped, "
        f"{counts['no_conf']} without a {args.conf_name} skipped",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
