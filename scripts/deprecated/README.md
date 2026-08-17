# Deprecated arcade scripts

Quarantined by issue #40 (2026-07-30). These implemented issue #30's
"on-demand ROM loading" architecture (pegasus-rom-launch dispatcher +
bubbletea-game-loader TUI + europa-side metadata generation), which could
never launch an eXo game: the dispatcher wasn't on the arcade session's
PATH, bubbletea's zip extraction flattened directory trees, the generated
metadata pointed `file:` at directories, emitted asset keys Pegasus doesn't
parse, and left descriptions/artwork empty despite the source XMLs carrying
them.

The replacement is scripts/exo-to-pegasus.py (metadata, run per-session by
modules/desktop/exodos.nix) + scripts/exo-launch.sh (extract-on-first-run
launcher). Nothing in the tree references these files; they are kept for a
release cycle as design reference for the eventual 1G1R console-collection
revival (which should be a `jupiter.arcade.gameDirs` contributor, not a
global launcher script).

- `pegasus-rom-launch` — Pegasus launcher.script dispatcher (launcher.script
  isn't even a Pegasus setting; Pegasus drops the key on save)
- `bubbletea-game-loader/` — download/extract TUI (flattens zips via
  filepath.Base; binaries test-build/test-loader removed from git)
- `generate-arcade-metadata.py` — 25-collection generator (emitted
  `launch: pegasus-rom-launch`, image matching missed sanitized filenames)
- `scrape-1g1r-metadata.py` — Hasheous enrichment for the 1G1R collections
- `generate-pegasus-collections/` — Minerva-ids → Pegasus txt (emitted the
  invalid `path:` key; output was never Pegasus-consumable)
- `setup-exowin9x.sh` / `download-exowin9x.sh` / `consolidate-collections.sh`
  / `extract-launchbox-metadata.sh` — one-shot europa provisioning/migration
  scripts whose jobs are done (consolidate-collections.sh is destructive if
  re-run: it zfs-destroys staging datasets)
- `cartridge-integrate.sh` — the transitional bulk-load watcher from the
  2026-07-31 cartridge pull (commit 4ba4f7f). Superseded by the declarative
  `jupiter-rom-verify` + `jupiter-rom-scrape` units; never wired into any
  module. Do not run it against the live tree: it promotes staged ROMs
  WITHOUT igir DAT verification and its minimal metadata seeds an unquoted
  `{file.path}` launch line that word-splits No-Intro paths.
- `validate-arcade-metadata.sh` / `verify-pegasus-artwork.sh` — validators
  that never worked: under `set -eu`, `((PASS++))` exits 1 on the first
  passing check; superseded by scripts/verify-exo-collections.sh
