// Package exo imports the eXo curated collections (eXoDOS / eXoWin3x /
// eXoWin9x) into the arcade-webapp store, READ-ONLY (gauntlet plan §2
// P8): the kiosk-side jupiter-exodos-metadata.service already generates
// each collection's metadata.pegasus.txt (scripts/exo-to-pegasus.py,
// run on every entry into the arcade session); this package parses those
// files — with the same strict parser generation validates against
// (internal/pegasus) — into real systems+games rows marked source=exo.
//
// What that buys the webapp: browse (library grid/detail), curation
// (hide/show + custom-collection membership) and coverage (art counts)
// over collections whose launcher DB is NOT ours. Generation for
// eXo-sourced systems stays kiosk-side by contract: internal/generate
// skips them (their files carry exo-launch conf paths under a mount we
// do not own), and the pipeline endpoints refuse them — this package is
// an import mirror, never a write path into the curated trees.
//
// Honesty contract: game identity is the parsed file: target relative to
// the collection root (a per-game emulator conf — the eXo launch anchor),
// size 0 (the bytes live on the kiosk mounts, not in any webapp bucket);
// enrichment fields land verbatim via SetGameMeta; box-front art presence
// lands as has_cover so "art %" means exactly what the legacy inventory's
// box_front grep meant.
package exo

import (
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/pegasus"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// Collection names one imported eXo collection: Key is the system key it
// lands under (and the shortname the kiosk files already declare), Dir is
// the subdirectory of the curated root holding its metadata.pegasus.txt.
type Collection struct {
	Key string // dos | win3x | win9x
	Dir string // exo-dos | exo-win3x | exo-win9x
}

// Collections is every curated collection the fleet mounts
// (arcade-inventory.nix's EXO_COLLECTIONS list — same three, same order).
var Collections = []Collection{
	{Key: "dos", Dir: "exo-dos"},
	{Key: "win3x", Dir: "exo-win3x"},
	{Key: "win9x", Dir: "exo-win9x"},
}

// Result summarizes one import pass (folded into scan warnings/telemetry).
type Result struct {
	Imported []string // collection keys whose metadata was found and parsed
	Games    int64    // game rows (re)written across all imported collections
	Art      int64    // games carrying assets.box_front
	Skipped  []string // collections with no metadata on this host (normal)
	Warnings []string // per-collection parse/persist failures (never fatal)
}

// exoSortBase pushes imported systems after every catalogue row (the TSV
// owns sort_order 1..61) so Systems() ordering stays stable and
// catalogue-first regardless of import order.
const exoSortBase = 1000

// Import parses <root>/<dir>/metadata.pegasus.txt for each configured
// collection and upserts its system + games rows. An absent metadata
// file skips silently (hosts without the curated mounts — the VM fixture
// materializes only what it asserts); a PRESENT but unparseable file is
// recorded as a warning, keeping whatever the previous import stored
// (mirroring the scanner's ADV-P1-03 keep-previous-rows posture).
func Import(st *store.Store, root string) Result {
	var res Result
	if strings.TrimSpace(root) == "" {
		return res
	}
	for i, col := range Collections {
		path := filepath.Join(root, col.Dir, "metadata.pegasus.txt")
		f, err := os.Open(path)
		if errors.Is(err, fs.ErrNotExist) {
			res.Skipped = append(res.Skipped, col.Key)
			continue
		}
		if err != nil {
			res.Warnings = append(res.Warnings, fmt.Sprintf("%s: %v", col.Key, err))
			continue
		}
		parsed, perr := pegasus.Parse(f)
		fClose := f.Close()
		if perr != nil {
			res.Warnings = append(res.Warnings, fmt.Sprintf("%s: parse %s: %v", col.Key, filepath.Base(path), perr))
			continue
		}
		if fClose != nil {
			res.Warnings = append(res.Warnings, fmt.Sprintf("%s: %v", col.Key, fClose))
			continue
		}

		games, art, werr := importCollection(st, col, parsed, exoSortBase+i)
		if werr != nil {
			res.Warnings = append(res.Warnings, fmt.Sprintf("%s: %v", col.Key, werr))
			continue
		}
		res.Imported = append(res.Imported, col.Key)
		res.Games += games
		res.Art += art
	}
	return res
}

// importCollection persists one parsed collection: system row, game rows,
// enrichment text, cover flags. Returns the persisted counts.
func importCollection(st *store.Store, col Collection, pf *pegasus.File, sortOrder int) (games, art int64, err error) {
	title := ""
	var blocks []pegasus.Game
	for _, c := range pf.Collections {
		if title == "" {
			title = c.Title
		}
		blocks = append(blocks, c.Games...)
	}
	if title == "" {
		title = "eXo " + col.Key
	}
	if err := st.UpsertExoSystem(store.SystemRow{
		Key:        col.Key,
		Collection: title,
		Bucket:     store.ExoBucket,
		Extensions: "[]",
		SortOrder:  sortOrder,
	}); err != nil {
		return 0, 0, err
	}

	rows := make([]store.GameRow, 0, len(blocks))
	metas := make([]store.GameMeta, 0, len(blocks))
	covers := make([]string, 0, len(blocks))
	seen := map[string]bool{}
	for _, g := range blocks {
		if g.File == "" || seen[g.File] {
			continue // defensive: Validate rejects these shapes anyway
		}
		seen[g.File] = true
		rows = append(rows, store.GameRow{RelPath: g.File, Title: g.Title})
		metas = append(metas, store.GameMeta{
			RelPath:     g.File,
			Description: field(g, "description"),
			Release:     field(g, "release"),
			Developer:   field(g, "developer"),
			Publisher:   field(g, "publisher"),
			Genre:       joinMulti(g, "genre"),
			Rating:      field(g, "rating"),
		})
		if g.Assets["box_front"] != "" {
			covers = append(covers, g.File)
		}
	}

	seenAt := time.Now().UTC()
	// ReplaceSystemGames preserves hidden/verify_state curation across
	// re-imports and prunes entries the source dropped — the same
	// rescan-never-clobbers contract catalogue systems get.
	if err := st.ReplaceSystemGames(col.Key, rows, seenAt); err != nil {
		return 0, 0, err
	}
	if len(metas) > 0 {
		if err := st.SetGameMeta(col.Key, metas); err != nil {
			return 0, 0, fmt.Errorf("enrichment: %w", err)
		}
	}
	if err := st.SetSystemCoverFlags(col.Key, covers); err != nil {
		return 0, 0, fmt.Errorf("cover flags: %w", err)
	}
	log.Printf("exo: imported %s (%s): %d games, %d with box art", col.Key, title, len(rows), len(covers))
	return int64(len(rows)), int64(len(covers)), nil
}

func field(g pegasus.Game, key string) string { return g.Fields[key] }

// joinMulti renders a repeated key ("genre:" lines) as "; "-joined text —
// the generator's sanitizeValue collapses newlines to "; " too, so the
// emitted form matches what a single-line value would look like.
func joinMulti(g pegasus.Game, key string) string {
	vals, ok := g.Multi[key]
	if !ok || len(vals) == 0 {
		return field(g, key) // single occurrence lives only in Fields
	}
	return strings.Join(vals, "; ")
}
