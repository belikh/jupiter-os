// Package pegasus is the arcade webapp's STRICT parser for
// metadata.pegasus.txt — the self-validation gate behind launcher-DB
// generation (gauntlet plan §2 P6 / AC-5): no generated file reaches a
// kiosk until this parser accepts it.
//
// Format contract (verified against scripts/cartridge-scrape.sh L128-133
// and Pegasus' MetaFile.cpp behaviour): a line is either blank, a `#`
// comment, or `key: value` where the value is EVERYTHING AFTER THE FIRST
// COLON, trimmed. There is NO quoting — quotes are literal bytes — and
// there are NO multi-line values in files we accept: an indented
// continuation line means some value carried a raw newline, so the parser
// rejects it outright instead of guessing where Pegasus would have ended
// the entry.
//
// Structure: `collection:` opens a collection block whose properties
// (shortname/summary/launch) precede its `game:` blocks; each game block
// carries `file:` plus optional enrichment fields (`description:`,
// `release:`, …) and media references (`assets.<key>:`). Validate() adds
// the generation-specific invariants on top of syntax: no duplicate
// file: targets across the whole file, no game without a file, a launch
// line on every playable (non-pending) collection.
package pegasus

import (
	"fmt"
	"io"
	"strings"
)

// PendingShortnameSuffix marks the trailing "(Pending)" collection the
// generator emits for incomplete ROMs: listed but deliberately NOT
// launchable (cartridge-scrape.sh's split_pending semantics).
const PendingShortnameSuffix = "-pending"

// IsPending reports whether a collection shortname belongs to a pending
// section (exempt from the launch-line requirement).
func IsPending(shortname string) bool {
	return strings.HasSuffix(shortname, PendingShortnameSuffix)
}

// Game is one parsed game block.
type Game struct {
	Title  string            // the `game:` value (display title)
	File   string            // the `file:` value (ROM path, relative)
	Fields map[string]string // other per-game keys (description, release, …); repeated keys keep the LAST value
	// Multi accumulates keys that appear MORE THAN ONCE in the block
	// (P8: eXo metadata emits one `genre:` / `tag:` line per value — a
	// last-wins map would silently drop all but one genre). Keys seen
	// once stay out of Multi; consumers join Multi values themselves.
	Multi  map[string][]string
	Assets map[string]string // assets.<key> → value (media paths)
}

// Collection is one parsed collection block: header properties plus its
// game blocks in file order.
type Collection struct {
	Title     string
	Shortname string
	Summary   string
	Launch    string // "" when absent (valid only for pending sections)
	Games     []Game
}

// File is a whole parsed metadata file: its collections in order.
type File struct {
	Collections []Collection
}

// Parse reads one metadata file. Syntax violations (colon-less lines,
// indented continuations i.e. newline-carrying values, collection
// properties after game blocks began, file/assets outside a game block)
// return errors naming the offending line.
func Parse(r io.Reader) (*File, error) {
	raw, err := io.ReadAll(r)
	if err != nil {
		return nil, fmt.Errorf("pegasus: read: %w", err)
	}
	f := &File{}
	var (
		cur   *Collection
		game  *Game
		inCol bool
	)
	flushGame := func(lineNo int) error {
		if game == nil {
			return nil
		}
		if cur == nil {
			return fmt.Errorf("pegasus: line %d: game block outside any collection", lineNo)
		}
		cur.Games = append(cur.Games, *game)
		game = nil
		return nil
	}
	for lineNo, line := range strings.Split(string(raw), "\n") {
		lineNo++ // 1-based for humans
		switch {
		case strings.TrimRight(line, "\r") == "":
			continue // separator; blocks key off game:/collection:, not blanks
		case strings.HasPrefix(line, "#"):
			continue // comment (the pending marker lives here)
		case line[0] == ' ' || line[0] == '\t':
			return nil, fmt.Errorf("pegasus: line %d: indented continuation line — a value carried a raw newline", lineNo)
		}
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			return nil, fmt.Errorf("pegasus: line %d: not key: value (%q)", lineNo, truncate(line))
		}
		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)

		switch {
		case key == "collection":
			if err := flushGame(lineNo); err != nil {
				return nil, err
			}
			f.Collections = append(f.Collections, Collection{Title: value})
			cur = &f.Collections[len(f.Collections)-1]
			inCol = true
		case !inCol:
			return nil, fmt.Errorf("pegasus: line %d: %s: before any collection:", lineNo, key)
		case key == "shortname":
			if game != nil || len(cur.Games) > 0 {
				return nil, fmt.Errorf("pegasus: line %d: shortname: after game blocks began", lineNo)
			}
			cur.Shortname = value
		case key == "summary":
			if game != nil || len(cur.Games) > 0 {
				return nil, fmt.Errorf("pegasus: line %d: summary: after game blocks began", lineNo)
			}
			cur.Summary = value
		case key == "launch":
			if game != nil || len(cur.Games) > 0 {
				return nil, fmt.Errorf("pegasus: line %d: launch: after game blocks began", lineNo)
			}
			cur.Launch = value
		case key == "game":
			if err := flushGame(lineNo); err != nil {
				return nil, err
			}
			game = &Game{Title: value}
		case key == "file":
			if game == nil {
				return nil, fmt.Errorf("pegasus: line %d: file: outside a game block", lineNo)
			}
			game.File = value
		case strings.HasPrefix(key, "assets."):
			if game == nil {
				return nil, fmt.Errorf("pegasus: line %d: %s: outside a game block", lineNo, key)
			}
			if game.Assets == nil {
				game.Assets = map[string]string{}
			}
			game.Assets[strings.TrimPrefix(key, "assets.")] = value
		default:
			if game == nil {
				continue // unknown collection-level property: tolerated, ignored
			}
			if game.Fields == nil {
				game.Fields = map[string]string{}
			}
			if prev, seen := game.Fields[key]; seen {
				// Second+ occurrence: start Multi from the FIRST value so
				// it carries every occurrence in file order.
				if game.Multi == nil {
					game.Multi = map[string][]string{}
				}
				if _, started := game.Multi[key]; !started {
					game.Multi[key] = []string{prev}
				}
				game.Multi[key] = append(game.Multi[key], value)
			}
			game.Fields[key] = value
		}
	}
	if err := flushGame(0); err != nil {
		return nil, err
	}
	if len(f.Collections) == 0 {
		return nil, fmt.Errorf("pegasus: no collections parsed")
	}
	return f, nil
}

// Validate enforces the generator's invariants on top of syntax:
//   - every game block names a file;
//   - no two game blocks share one file: target WITHIN one collection
//     (Pegasus would list the ROM twice in the same grid). The SAME file
//     under a DIFFERENT collection in this file is legal and is exactly
//     how Pegasus expresses multi-collection membership — P7 custom
//     collections repeat member blocks after the main collection, so
//     whole-file uniqueness was deliberately relaxed to per-collection;
//   - no two collections share one shortname within one file (the same
//     collection name recurring across FILES is the documented cross-file
//     merge and is fine — each Parse sees one file);
//   - every PLAYABLE collection carries a launch line — the main
//     collection above all (a launch-less main collection is exactly the
//     unlaunchable state seed_launchable_metadata existed to repair).
//     Pending sections are exempt by design ("listed, not yet playable").
func (f *File) Validate() error {
	seenShort := map[string]string{} // shortname → collection title
	for ci := range f.Collections {
		col := &f.Collections[ci]
		if col.Shortname != "" {
			if prev, dup := seenShort[col.Shortname]; dup {
				return fmt.Errorf("pegasus: duplicate collection shortname %q (%s and %s)", col.Shortname, prev, col.Title)
			}
			seenShort[col.Shortname] = col.Title
		}
		if col.Launch == "" && !IsPending(col.Shortname) && len(col.Games) > 0 {
			return fmt.Errorf("pegasus: collection %q (%s) has no launch line", col.Title, col.Shortname)
		}
		seen := map[string]string{} // file target → game title, within THIS collection
		for _, g := range col.Games {
			if g.File == "" {
				return fmt.Errorf("pegasus: game %q has no file entry", g.Title)
			}
			if prev, dup := seen[g.File]; dup {
				return fmt.Errorf("pegasus: duplicate file target %q in collection %q (games %q and %q)", g.File, col.Title, prev, g.Title)
			}
			seen[g.File] = g.Title
		}
	}
	if len(f.Collections) == 0 {
		return fmt.Errorf("pegasus: nothing to validate")
	}
	return nil
}

func truncate(s string) string {
	if len(s) <= 60 {
		return s
	}
	return s[:57] + "…"
}
