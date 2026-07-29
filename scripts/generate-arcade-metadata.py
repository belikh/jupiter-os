#!/usr/bin/env python3
"""
generate-arcade-metadata.py — Generate Pegasus collection files from NFS sources.

Reads:
- LaunchBox XML (eXoDOS, eXoWin3x, C64 Dreams, etc.)
- DAT files (No-Intro, Redump, TOSEC) for 1G1R
- Directory scans (OneLoad64, Mega-AGS, etc.)

Outputs:
- /tank/archive/retro/metadata/pegasus/collections/*.txt (Pegasus collection files)
- Assets symlinked in /tank/archive/retro/metadata/pegasus/assets/

Run on europa (NAS) or at build time.
"""

import argparse
import hashlib
import os
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import List, Tuple

# --- Pegasus metadata helpers -------------------------------------------------

def escape_value(v: str) -> str:
    return v.lstrip()

def render_game_entry(
    title: str,
    file_rel: str,
    developer: str = "",
    publisher: str = "",
    genres: List[str] = None,
    release: str = "",
    summary: str = "",
    rating: str = "",
    favorite: bool = False,
    logo: str = "",
    screenshot: str = "",
    boxfront: str = "",
    marquee: str = "",
) -> str:
    lines = [f"game: {escape_value(title)}"]
    if file_rel:
        lines.append(f"file: {file_rel}")
    if developer:
        lines.append(f"developer: {escape_value(developer)}")
    if publisher:
        lines.append(f"publisher: {escape_value(publisher)}")
    for g in genres or []:
        lines.append(f"genre: {escape_value(g)}")
    if release:
        lines.append(f"release: {release}")
    if summary:
        lines.append(f"summary: {escape_value(summary)}")
    if rating:
        lines.append(f"rating: {rating}")
    if logo:
        lines.append(f"logo: {escape_value(logo)}")
    if screenshot:
        lines.append(f"screenshot: {escape_value(screenshot)}")
    if boxfront:
        lines.append(f"image: {escape_value(boxfront)}")
    if marquee:
        lines.append(f"marquee: {escape_value(marquee)}")
    if favorite:
        lines.append("x-favorite: true")
    lines.append("")
    return "\n".join(lines)


# --- LaunchBox XML parser (eXoDOS, eXoWin3x, C64 Dreams, etc.) ---------------

def parse_launchbox_xml(
    xml_path: Path,
    collection_root: Path,
    collection_name: str,
    shortname: str,
    emulator: str,
    rewrites: List[Tuple[str, str]],
) -> str:
    tree = ET.parse(xml_path)
    root = tree.getroot()

    out = [
        f"# Generated from {xml_path.name}",
        f"# Collection: {collection_name}",
        f"# Emulator: {emulator}",
        "",
        f"collection: {collection_name}",
        f"shortname: {shortname}",
        f"launch: pegasus-rom-launch {{file.path}}",
        "",
    ]

    for game in root.findall("Game"):
        # Skip hidden/broken
        if game.find("Hide") is not None and game.find("Hide").text == "True":
            continue
        if game.find("Broken") is not None and game.find("Broken").text == "True":
            continue

        title = game.find("Title")
        title = title.text.strip() if title is not None and title.text else "(untitled)"

        app_path = game.find("ApplicationPath")
        if app_path is None or not app_path.text:
            continue

        # Convert Windows path to POSIX
        posix_path = app_path.text.replace("\\", "/")
        for old, new in rewrites:
            posix_path = posix_path.replace(old, new)

        game_dir = os.path.dirname(posix_path)
        file_rel = f"{game_dir}/dosbox.conf"  # Pegasus calls launcher with this

        dev = game.find("Developer")
        pub = game.find("Publisher")
        genre = game.find("Genre")
        rel = game.find("ReleaseDate")
        notes = game.find("Notes")
        rating = game.find("CommunityStarRating")
        fav = game.find("Favorite")
        lbid = game.find("ID")
        manual = game.find("ManualPath")
        img = game.find("ImagePath")
        box = game.find("BoxFrontImagePath")
        scr = game.find("ScreenshotImagePath")
        wheel = game.find("WheelImagePath")
        marq = game.find("MarqueeImagePath")

        def txt(el):
            return el.text.strip() if el is not None and el.text else ""

        def img_rel(path):
            if not path:
                return ""
            p = path.replace("\\", "/")
            for o, n in rewrites:
                p = p.replace(o, n)
            return p.lower()

        out.append(render_game_entry(
            title=title,
            file_rel=file_rel,
            developer=txt(dev),
            publisher=txt(pub),
            genres=[g.strip() for g in txt(genre).split(";") if g.strip()],
            release=txt(rel)[:10] if txt(rel) else "",
            summary=" ".join(txt(notes).split()),
            rating=f"{round(float(txt(rating))*20)}%" if txt(rating) else "",
            favorite=txt(fav).lower() == "true",
            logo=img_rel(wheel),
            screenshot=img_rel(scr),
            boxfront=img_rel(box),
            marquee=img_rel(marq),
        ))

    return "\n".join(out)


# --- DAT file parser (No-Intro, Redump, TOSEC) for 1G1R ----------------------

def parse_dat_file(dat_path: Path, collection_name: str, shortname: str) -> str:
    """
    Parse a DAT file (XML format from No-Intro/Redump/TOSEC) and generate
    Pegasus entries with Myrient mirror URLs.
    """
    tree = ET.parse(dat_path)
    root = tree.getroot()

    # Determine system from DAT name
    dat_name = dat_path.stem.lower()
    system_map = {
        "nointro-nes": ("Nintendo - Nintendo Entertainment System", "retroarch", "nes"),
        "nointro-snes": ("Nintendo - Super Nintendo Entertainment System", "retroarch", "snes"),
        "nointro-gb": ("Nintendo - Game Boy", "retroarch", "gb"),
        "nointro-gbc": ("Nintendo - Game Boy Color", "retroarch", "gbc"),
        "nointro-gba": ("Nintendo - Game Boy Advance", "retroarch", "gba"),
        "nointro-n64": ("Nintendo - Nintendo 64", "retroarch", "n64"),
        "nointro-ds": ("Nintendo - Nintendo DS", "retroarch", "nds"),
        "redump-ps1": ("Sony - PlayStation", "retroarch", "ps1"),
        "redump-ps2": ("Sony - PlayStation 2", "retroarch", "ps2"),
        "redump-psp": ("Sony - PlayStation Portable", "retroarch", "psp"),
        "redump-saturn": ("Sega - Saturn", "retroarch", "saturn"),
        "redump-dreamcast": ("Sega - Dreamcast", "retroarch", "dreamcast"),
        "redump-gamecube": ("Nintendo - GameCube", "retroarch", "gc"),
        "redump-wii": ("Nintendo - Wii", "retroarch", "wii"),
        "redump-xbox": ("Microsoft - Xbox", "retroarch", "xbox"),
    }

    system_full, emulator, core = system_map.get(
        dat_name, (dat_name.replace("-", " ").title(), "retroarch", "auto")
    )

    out = [
        f"# Generated from {dat_path.name}",
        f"# System: {system_full}",
        f"# Emulator: {emulator} ({core})",
        "",
        f"collection: {collection_name}",
        f"shortname: {shortname}",
        f"launch: pegasus-rom-launch 1g1r-{shortname}/{{file.name}}",
        "",
    ]

    for game in root.findall("game"):
        name = game.get("name", "")
        if not name:
            continue

        rom = game.find("rom")
        if rom is None:
            continue

        file_name = rom.get("name", "")
        if not file_name:
            continue

        # Clean up name for display
        display_name = re.sub(r'\s*\([^)]*\)', '', name).strip()
        display_name = re.sub(r'\s*\[.*?\]', '', display_name).strip()

        # 1G1R entries point to relative path that launcher resolves to Myrient URL
        out.append(render_game_entry(
            title=display_name,
            file_rel=f"{file_name}",
            genres=[system_full],
        ))

    return "\n".join(out)


# --- Directory scanner (OneLoad64, Mega-AGS, etc.) ----------------------------

def scan_directory(
    dir_path: Path,
    collection_name: str,
    shortname: str,
    emulator: str,
    extensions: List[str],
    launch_prefix: str,
) -> str:
    out = [
        f"# Generated from directory scan: {dir_path}",
        f"# Collection: {collection_name}",
        "",
        f"collection: {collection_name}",
        f"shortname: {shortname}",
        f"launch: {launch_prefix} {{file.path}}",
        "",
    ]

    for ext in extensions:
        for rom_path in sorted(dir_path.rglob(f"*{ext}")):
            rel = rom_path.relative_to(dir_path)
            name = rom_path.stem
            # Clean name
            name = re.sub(r'\s*\([^)]*\)', '', name).strip()
            name = re.sub(r'\s*\[.*?\]', '', name).strip()

            out.append(render_game_entry(
                title=name,
                file_rel=str(rel),
                genres=[collection_name],
            ))

    return "\n".join(out)


# --- Asset symlinker ----------------------------------------------------------

def symlink_assets(source_root: Path, assets_root: Path) -> None:
    """Symlink boxart, screenshots, logos from collection source to assets dir."""
    asset_types = {
        "boxart": ["BoxFront", "Box Front", "boxfront", "boxart"],
        "screenshots": ["Screenshot", "screenshot", "Screenshots"],
        "logos": ["Wheel", "wheel", "Logo", "logo", "Marquee", "marquee"],
    }

    for asset_dir, search_names in asset_types.items():
        target = assets_root / asset_dir
        target.mkdir(parents=True, exist_ok=True)

        for search in search_names:
            for src in source_root.rglob(f"*{search}*"):
                if src.is_file() and src.suffix.lower() in [".png", ".jpg", ".jpeg", ".webp"]:
                    rel = src.relative_to(source_root)
                    dst = target / rel
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    try:
                        dst.unlink()
                    except FileNotFoundError:
                        pass
                    dst.symlink_to(src)


# --- Main --------------------------------------------------------------------

# --- Collection categories ----------------------------------------------------

CURATED_COLLECTIONS = [
    "curated-exo-dos",
    "curated-exo-win3x",
    "curated-c64-dreams",
    "curated-oneload64",
    "curated-exo-if",
    "curated-exo-demos",
    "curated-exo-appleiigs",
    "curated-exo-scummvm",
    "curated-exo-win9x",
    "curated-megaags",
]

ONE_G1R_COLLECTIONS = [
    "1g1r-nointro-nes",
    "1g1r-nointro-snes",
    "1g1r-nointro-gb",
    "1g1r-nointro-gbc",
    "1g1r-nointro-gba",
    "1g1r-nointro-n64",
    "1g1r-nointro-ds",
    "1g1r-redump-ps1",
    "1g1r-redump-ps2",
    "1g1r-redump-psp",
    "1g1r-redump-saturn",
    "1g1r-redump-dreamcast",
    "1g1r-redump-gamecube",
    "1g1r-redump-wii",
    "1g1r-redump-xbox",
]

ALL_COLLECTIONS = CURATED_COLLECTIONS + ONE_G1R_COLLECTIONS


def get_collections(nfs_root: Path) -> dict:
    """Return the collections dict, built dynamically from categories."""
    return {
        # Curated: LaunchBox XML based
        "curated-exo-dos": {
            "type": "launchbox",
            "xml": nfs_root / "retro/games/curated/exo-dos/xml/MS-DOS.xml",
            "root": nfs_root / "retro/games/curated/exo-dos",
            "name": "eXoDOS",
            "shortname": "dos",
            "emulator": "dosbox",
            "rewrites": [("eXoDOS", "exo-dos"), ("eXo", "exo")],
            "assets_src": nfs_root / "retro/games/curated/exo-dos",
        },
        "curated-exo-win3x": {
            "type": "launchbox",
            "xml": nfs_root / "retro/games/curated/exo-win3x/xml/Windows 3x.xml",
            "root": nfs_root / "retro/games/curated/exo-win3x",
            "name": "eXoWin3x",
            "shortname": "win3x",
            "emulator": "dosbox-x",
            "rewrites": [("eXoWin3X", "exo-win3x"), ("eXoWin3x", "exo-win3x")],
            "assets_src": nfs_root / "retro/games/curated/exo-win3x",
        },
        "curated-c64-dreams": {
            "type": "launchbox",
            "xml": nfs_root / "retro/games/curated/c64-dreams/LaunchBox/Data/Platforms/Commodore 64.xml",
            "root": nfs_root / "retro/games/curated/c64-dreams",
            "name": "C64 Dreams",
            "shortname": "c64",
            "emulator": "vice",
            "rewrites": [],
            "assets_src": nfs_root / "retro/games/curated/c64-dreams/LaunchBox/Images",
        },
        "curated-oneload64": {
            "type": "dirscan",
            "root": nfs_root / "retro/games/curated/oneload64",
            "name": "OneLoad64",
            "shortname": "oneload64",
            "emulator": "vice",
            "extensions": [".crt"],
            "launch_prefix": "pegasus-rom-launch",
            "assets_src": nfs_root / "retro/games/curated/oneload64",
        },
        "curated-exo-if": {
            "type": "dirscan",
            "root": nfs_root / "retro/games/curated/exo-if",
            "name": "eXoIF",
            "shortname": "if",
            "emulator": "gargoyle",
            "extensions": [".z5", ".z8", ".dat"],
            "launch_prefix": "pegasus-rom-launch",
            "assets_src": nfs_root / "retro/games/curated/exo-if",
        },
        "curated-exo-demos": {
            "type": "dirscan",
            "root": nfs_root / "retro/games/curated/exo-demos",
            "name": "eXoDemoScene",
            "shortname": "demos",
            "emulator": "dosbox",
            "extensions": [".exe", ".com", ".bat"],
            "launch_prefix": "pegasus-rom-launch",
            "assets_src": nfs_root / "retro/games/curated/exo-demos",
        },
        "curated-exo-appleiigs": {
            "type": "dirscan",
            "root": nfs_root / "retro/games/curated/exo-appleiigs",
            "name": "eXoAppleIIGS",
            "shortname": "appleiigs",
            "emulator": "gsplus",
            "extensions": [".2mg", ".po", ".dsk"],
            "launch_prefix": "pegasus-rom-launch",
            "assets_src": nfs_root / "retro/games/curated/exo-appleiigs",
        },
        "curated-exo-scummvm": {
            "type": "dirscan",
            "root": nfs_root / "retro/games/curated/exo-scummvm",
            "name": "eXoScummVM",
            "shortname": "scummvm",
            "emulator": "scummvm",
            "extensions": [".svm"],
            "launch_prefix": "pegasus-rom-launch",
            "assets_src": nfs_root / "retro/games/curated/exo-scummvm",
        },
        "curated-exo-win9x": {
            "type": "dirscan",
            "root": nfs_root / "retro/games/curated/exo-win9x",
            "name": "eXoWin9x",
            "shortname": "win9x",
            "emulator": "pcem",
            "extensions": [".exe", ".bat"],
            "launch_prefix": "pegasus-rom-launch",
            "assets_src": nfs_root / "retro/games/curated/exo-win9x",
        },
        "curated-megaags": {
            "type": "dirscan",
            "root": nfs_root / "retro/games/curated/megaags",
            "name": "Mega-AGS / AmigaVision",
            "shortname": "amiga",
            "emulator": "fs-uae",
            "extensions": [".lha", ".adf", ".hdf"],
            "launch_prefix": "pegasus-rom-launch",
            "assets_src": nfs_root / "retro/games/curated/megaags",
        },
        # 1G1R: DAT based
        "1g1r-nointro-nes": {"type": "dat", "dat": nfs_root / "retro/games/1g1r/nointro-nes.dat", "name": "NES (1G1R)", "shortname": "nointro-nes"},
        "1g1r-nointro-snes": {"type": "dat", "dat": nfs_root / "retro/games/1g1r/nointro-snes.dat", "name": "SNES (1G1R)", "shortname": "nointro-snes"},
        "1g1r-nointro-gb": {"type": "dat", "dat": nfs_root / "retro/games/1g1r/nointro-gb.dat", "name": "Game Boy (1G1R)", "shortname": "nointro-gb"},
        "1g1r-nointro-gbc": {"type": "dat", "dat": nfs_root / "retro/games/1g1r/nointro-gbc.dat", "name": "Game Boy Color (1G1R)", "shortname": "nointro-gbc"},
        "1g1r-nointro-gba": {"type": "dat", "dat": nfs_root / "retro/games/1g1r/nointro-gba.dat", "name": "Game Boy Advance (1G1R)", "shortname": "nointro-gba"},
        "1g1r-nointro-n64": {"type": "dat", "dat": nfs_root / "retro/games/1g1r/nointro-n64.dat", "name": "Nintendo 64 (1G1R)", "shortname": "nointro-n64"},
        "1g1r-nointro-ds": {"type": "dat", "dat": nfs_root / "retro/games/1g1r/nointro-ds.dat", "name": "Nintendo DS (1G1R)", "shortname": "nointro-ds"},
        "1g1r-redump-ps1": {"type": "dat", "dat": nfs_root / "retro/games/1g1r/redump-ps1.dat", "name": "PlayStation (1G1R)", "shortname": "redump-ps1"},
        "1g1r-redump-ps2": {"type": "dat", "dat": nfs_root / "retro/games/1g1r/redump-ps2.dat", "name": "PlayStation 2 (1G1R)", "shortname": "redump-ps2"},
        "1g1r-redump-psp": {"type": "dat", "dat": nfs_root / "retro/games/1g1r/redump-psp.dat", "name": "PSP (1G1R)", "shortname": "redump-psp"},
        "1g1r-redump-saturn": {"type": "dat", "dat": nfs_root / "retro/games/1g1r/redump-saturn.dat", "name": "Saturn (1G1R)", "shortname": "redump-saturn"},
        "1g1r-redump-dreamcast": {"type": "dat", "dat": nfs_root / "retro/games/1g1r/redump-dreamcast.dat", "name": "Dreamcast (1G1R)", "shortname": "redump-dreamcast"},
        "1g1r-redump-gamecube": {"type": "dat", "dat": nfs_root / "retro/games/1g1r/redump-gamecube.dat", "name": "GameCube (1G1R)", "shortname": "redump-gamecube"},
        "1g1r-redump-wii": {"type": "dat", "dat": nfs_root / "retro/games/1g1r/redump-wii.dat", "name": "Wii (1G1R)", "shortname": "redump-wii"},
        "1g1r-redump-xbox": {"type": "dat", "dat": nfs_root / "retro/games/1g1r/redump-xbox.dat", "name": "Xbox (1G1R)", "shortname": "redump-xbox"},
    }


def generate_collections(
    nfs_root: Path,
    out_dir: Path,
    assets_dir: Path,
    collections_to_generate: list,
) -> None:
    """Generate collection files for the given list of collection keys."""
    all_collections = get_collections(nfs_root)

    for key in collections_to_generate:
        if key not in all_collections:
            print(f"Unknown collection: {key}", file=sys.stderr)
            continue

        c = all_collections[key]
        print(f"Generating {key}...")
        content = ""

        # Pegasus expects each collection as a .txt file in the collections directory
        # (not subdirectories). Format: collection_name.txt containing metadata.pegasus.txt content
        output_file = out_dir / f"{key}.txt"

        if c["type"] == "launchbox":
            if c["xml"].exists():
                content = parse_launchbox_xml(
                    c["xml"], c["root"], c["name"], c["shortname"], c["emulator"], c.get("rewrites", [])
                )
                output_file.write_text(content)
                if "assets_src" in c and c["assets_src"].exists():
                    symlink_assets(c["assets_src"], assets_dir / key)
            else:
                print(f"  WARNING: XML not found: {c['xml']}", file=sys.stderr)

        elif c["type"] == "dat":
            if c["dat"].exists():
                content = parse_dat_file(c["dat"], c["name"], c["shortname"])
                output_file.write_text(content)
            else:
                print(f"  WARNING: DAT not found: {c['dat']}", file=sys.stderr)

        elif c["type"] == "dirscan":
            if c["root"].exists():
                content = scan_directory(
                    c["root"], c["name"], c["shortname"], c["emulator"],
                    c["extensions"], c["launch_prefix"]
                )
                output_file.write_text(content)
                if "assets_src" in c and c["assets_src"].exists():
                    symlink_assets(c["assets_src"], assets_dir / key)
            else:
                print(f"  WARNING: Root not found: {c['root']}", file=sys.stderr)


def main():
    p = argparse.ArgumentParser(description="Generate Pegasus metadata for jupiterOS Arcade")
    p.add_argument("--nfs-root", required=True, help="NFS mount root (e.g. /tank/archive)")
    p.add_argument("--output", required=True, help="Output directory for collection files (all collections)")
    p.add_argument("--curated-output", help="Output directory for curated-only collection files (for kiosks)")
    p.add_argument("--assets", required=True, help="Assets output directory")
    p.add_argument("--collections", nargs="+", default=["all"],
                   help="Collections to generate (default: all)")
    args = p.parse_args()

    nfs_root = Path(args.nfs_root)
    out_dir = Path(args.output)
    assets_dir = Path(args.assets)

    out_dir.mkdir(parents=True, exist_ok=True)
    assets_dir.mkdir(parents=True, exist_ok=True)

    # Parse --collections argument
    if args.collections == ["curated"]:
        selected = CURATED_COLLECTIONS
    elif args.collections == ["1g1r"]:
        selected = ONE_G1R_COLLECTIONS
    elif args.collections == ["all"]:
        selected = ALL_COLLECTIONS
    else:
        selected = args.collections

    generate_collections(nfs_root, out_dir, assets_dir, selected)

    # If --curated-output is specified, also generate curated collections there
    if args.curated_output:
        curated_dir = Path(args.curated_output)
        curated_dir.mkdir(parents=True, exist_ok=True)
        curated_assets = assets_dir  # share assets dir
        generate_collections(nfs_root, curated_dir, curated_assets, CURATED_COLLECTIONS)

    print("Done.")


if __name__ == "__main__":
    main()