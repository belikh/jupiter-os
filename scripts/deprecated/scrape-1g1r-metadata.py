#!/usr/bin/env python3
"""
scrape-1g1r-metadata.py — Enrich 1G1R collections with metadata + assets via Hasheous.

Reads generated Pegasus collection files, looks up each ROM's hash in Hasheous,
downloads boxart/screenshots/logos, and rewrites the collection with full metadata.

Run on europa (NAS) after generate-arcade-metadata.py.
"""

import argparse
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import requests

HASHEOUS_BASE = "https://hasheous.org/api/v1"

# Hasheous platform IDs for No-Intro/Redump systems
PLATFORM_MAP = {
    "1g1r-nointro-nes": "Nintendo - Nintendo Entertainment System",
    "1g1r-nointro-snes": "Nintendo - Super Nintendo Entertainment System",
    "1g1r-nointro-gb": "Nintendo - Game Boy",
    "1g1r-nointro-gbc": "Nintendo - Game Boy Color",
    "1g1r-nointro-gba": "Nintendo - Game Boy Advance",
    "1g1r-nointro-n64": "Nintendo - Nintendo 64",
    "1g1r-nointro-ds": "Nintendo - Nintendo DS",
    "1g1r-redump-ps1": "Sony - PlayStation",
    "1g1r-redump-ps2": "Sony - PlayStation 2",
    "1g1r-redump-psp": "Sony - PlayStation Portable",
    "1g1r-redump-saturn": "Sega - Saturn",
    "1g1r-redump-dreamcast": "Sega - Dreamcast",
    "1g1r-redump-gamecube": "Nintendo - GameCube",
    "1g1r-redump-wii": "Nintendo - Wii",
    "1g1r-redump-xbox": "Microsoft - Xbox",
}

RATE_LIMIT_DEFAULT = 0.1  # 10 req/sec max


def parse_args():
    p = argparse.ArgumentParser(
        description="Enrich 1G1R Pegasus collections with Hasheous metadata"
    )
    p.add_argument(
        "--collections-dir", required=True, help="Directory containing .txt collection files"
    )
    p.add_argument("--assets-dir", required=True, help="Assets output directory")
    p.add_argument(
        "--collections",
        nargs="+",
        default=["all"],
        help="Collection keys to process (default: all 1g1r)",
    )
    p.add_argument(
        "--rate-limit", type=float, default=RATE_LIMIT_DEFAULT, help="Seconds between API calls"
    )
    p.add_argument("--force", action="store_true", help="Re-process even if already enriched")
    return p.parse_args()


def parse_pegasus_collection(filepath: Path) -> Tuple[Dict, List[Dict]]:
    """Parse a Pegasus collection .txt file into header dict + list of game dicts."""
    header = {}
    games = []
    current_game = {}

    with open(filepath, "r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                if current_game:
                    games.append(current_game)
                    current_game = {}
                continue

            if ":" not in line:
                continue

            key, value = line.split(":", 1)
            key = key.strip().lower()
            value = value.strip()

            if key == "game":
                if current_game:
                    games.append(current_game)
                current_game = {"title": value}
            elif key in (
                "file",
                "developer",
                "publisher",
                "genre",
                "release",
                "summary",
                "rating",
                "logo",
                "screenshot",
                "image",
                "marquee",
                "x-favorite",
                "x-lb-id",
                "x-manual",
            ):
                if key == "file":
                    current_game["file_rel"] = value
                elif key == "image":
                    current_game["boxfront"] = value
                else:
                    current_game[key.replace("-", "_")] = value
            else:
                header[key] = value

    if current_game:
        games.append(current_game)

    return header, games


def lookup_hash(hashes: Dict[str, str], rate_limit: float) -> Optional[Dict]:
    """Query Hasheous /api/v1/Lookup/ByHash with CRC/MD5/SHA1/SHA256."""
    payload = {k: v for k, v in hashes.items() if v}
    if not payload:
        return None

    try:
        resp = requests.post(
            f"{HASHEOUS_BASE}/Lookup/ByHash?returnAllSources=true&returnFields=All",
            json=payload,
            timeout=15,
        )
        if resp.status_code == 404:
            return None
        resp.raise_for_status()
        time.sleep(rate_limit)
        return resp.json()
    except requests.RequestException as e:
        print(f"  Lookup error: {e}", file=sys.stderr)
        return None


def extract_igdb_id(lookup_result: Dict) -> Optional[int]:
    """Extract IGDB game ID from Hasheous lookup result."""
    for meta in lookup_result.get("metadata", []):
        if meta.get("source") == "IGDB" and meta.get("externalId"):
            try:
                return int(meta["externalId"])
            except ValueError:
                pass
    return None


def download_image(url: str, dest: Path, rate_limit: float) -> bool:
    """Download an image from Hasheous image proxy."""
    try:
        resp = requests.get(url, timeout=30)
        if resp.status_code == 200:
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(resp.content)
            time.sleep(rate_limit)
            return True
    except requests.RequestException:
        pass
    return False


def download_igdb_assets(igdb_id: int, assets_dir: Path, game_slug: str, rate_limit: float) -> Dict[str, str]:
    """Download boxart, screenshot, logo, marquee from IGDB via Hasheous proxy."""
    asset_paths = {}

    # Hasheous serves IGDB images at /api/v1/MetadataProxy/Bundles/IGDB/{igdb_id}/{type}.jpg
    # Types: cover (boxart), screenshot, logo, marquee
    image_types = {
        "boxfront": "cover",
        "screenshot": "screenshot",
        "logo": "logo",
        "marquee": "marquee",
    }

    for local_name, remote_type in image_types.items():
        url = f"{HASHEOUS_BASE}/MetadataProxy/Bundles/IGDB/{igdb_id}/{remote_type}.jpg"
        dest = assets_dir / game_slug / f"{local_name}.jpg"
        if download_image(url, dest, rate_limit):
            asset_paths[local_name] = str(dest.relative_to(assets_dir.parent))

    return asset_paths


def enrich_collection(
    collection_key: str,
    collections_dir: Path,
    assets_dir: Path,
    rate_limit: float,
    force: bool,
) -> int:
    """Enrich a single 1G1R collection file with Hasheous metadata."""
    filepath = collections_dir / f"{collection_key}.txt"
    if not filepath.exists():
        print(f"  File not found: {filepath}")
        return 0

    header, games = parse_pegasus_collection(filepath)
    print(f"Processing {collection_key}: {len(games)} games")

    # System slug for asset subdirectory
    system_slug = collection_key.replace("1g1r-", "").replace("nointro-", "").replace("redump-", "")
    system_assets_dir = assets_dir / system_slug
    system_assets_dir.mkdir(parents=True, exist_ok=True)

    enriched = 0
    for game in games:
        file_rel = game.get("file_rel", "")
        if not file_rel:
            continue

        # Check if already enriched
        if not force and (game.get("boxfront") or game.get("logo")):
            continue

        # Hash the ROM file
        rom_path = Path("/tank/archive/retro/games") / collection_key / file_rel
        if not rom_path.exists():
            # Try alternative paths
            for alt in [
                Path("/tank/archive/retro/games/1g1r") / system_slug / file_rel,
                Path("/tank/archive/retro/games") / file_rel,
            ]:
                if alt.exists():
                    rom_path = alt
                    break
            else:
                # Skip if ROM not found locally (will be downloaded on-demand on kiosk)
                continue

        # Compute hashes
        try:
            data = rom_path.read_bytes()
            hashes = {
                "crc": f"{hashlib.crc32(data) & 0xffffffff:08x}",
                "md5": hashlib.md5(data).hexdigest(),
                "sha1": hashlib.sha1(data).hexdigest(),
                "sha256": hashlib.sha256(data).hexdigest(),
            }
        except OSError:
            continue

        print(f"  {game['title']} - CRC: {hashes['crc']}")

        result = lookup_hash(hashes, rate_limit)
        if not result:
            print(f"    No match in Hasheous")
            continue

        igdb_id = extract_igdb_id(result)
        if not igdb_id:
            print(f"    No IGDB ID found")
            continue

        print(f"    Matched IGDB ID: {igdb_id}")

        # Extract metadata from lookup result
        for meta in result.get("metadata", []):
            if meta.get("source") == "IGDB":
                if not game.get("developer") and meta.get("developer"):
                    game["developer"] = meta["developer"]
                if not game.get("publisher") and meta.get("publisher"):
                    game["publisher"] = meta["publisher"]
                if not game.get("genre") and meta.get("genres"):
                    game["genre"] = ";".join(meta["genres"])
                if not game.get("release") and meta.get("firstReleaseDate"):
                    game["release"] = meta["firstReleaseDate"][:10]
                if not game.get("summary") and meta.get("summary"):
                    game["summary"] = " ".join(meta["summary"].split())
                break

        # Download assets
        game_slug = re.sub(r"[^\w\-]", "_", game["title"].lower())[:80]
        assets = download_igdb_assets(igdb_id, system_assets_dir, game_slug, rate_limit)
        game.update(assets)
        enriched += 1

    if enriched:
        write_pegasus_collection(filepath, header, games)
        print(f"  Enriched {enriched} games")

    return enriched


def write_pegasus_collection(filepath: Path, header: Dict, games: List[Dict]):
    """Write enriched collection back to .txt file."""
    lines = []
    for k, v in header.items():
        lines.append(f"{k}: {v}")
    lines.append("")

    for game in games:
        lines.append(f"game: {game.get('title', '(untitled)')}")
        if game.get("file_rel"):
            lines.append(f"file: {game['file_rel']}")
        if game.get("developer"):
            lines.append(f"developer: {game['developer']}")
        if game.get("publisher"):
            lines.append(f"publisher: {game['publisher']}")
        for g in (game.get("genre", "") or "").split(";"):
            if g.strip():
                lines.append(f"genre: {g.strip()}")
        if game.get("release"):
            lines.append(f"release: {game['release']}")
        if game.get("summary"):
            lines.append(f"summary: {game['summary']}")
        if game.get("rating"):
            lines.append(f"rating: {game['rating']}")
        if game.get("logo"):
            lines.append(f"logo: {game['logo']}")
        if game.get("screenshot"):
            lines.append(f"screenshot: {game['screenshot']}")
        if game.get("boxfront"):
            lines.append(f"image: {game['boxfront']}")
        if game.get("marquee"):
            lines.append(f"marquee: {game['marquee']}")
        if game.get("x_favorite"):
            lines.append(f"x-favorite: {game['x_favorite']}")
        if game.get("x_lb_id"):
            lines.append(f"x-lb-id: {game['x_lb_id']}")
        if game.get("x_manual"):
            lines.append(f"x-manual: {game['x_manual']}")
        lines.append("")

    filepath.write_text("\n".join(lines), encoding="utf-8")


def main():
    args = parse_args()

    collections_dir = Path(args.collections_dir)
    assets_dir = Path(args.assets_dir)

    if not collections_dir.exists():
        print(f"Collections dir not found: {collections_dir}", file=sys.stderr)
        return 1

    assets_dir.mkdir(parents=True, exist_ok=True)

    # All 1G1R collection keys
    all_collections = list(PLATFORM_MAP.keys())

    if args.collections == ["all"] or args.collections == ["1g1r"]:
        selected = all_collections
    else:
        selected = []
        for name in args.collections:
            if not name.startswith("1g1r-"):
                name = f"1g1r-{name}"
            if name in PLATFORM_MAP:
                selected.append(name)

    print(f"Found {len(selected)} 1G1R collections to process")

    total_enriched = 0
    for key in selected:
        total_enriched += enrich_collection(key, collections_dir, assets_dir, args.rate_limit, args.force)

    print(f"\nDone. Enriched {total_enriched} games total.")
    return 0


if __name__ == "__main__":
    sys.exit(main())