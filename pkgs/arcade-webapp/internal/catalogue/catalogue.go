// Package catalogue parses scripts/cartridge-catalogue.tsv — the single
// source of truth for jupiterOS Arcade system facts — with the same
// semantics modules/services/arcade-catalogue.nix applies on the Nix side:
// TAB-separated columns, "-" meaning "not applicable", "#" comments and
// blank lines skipped. The webapp imports the TSV itself (gauntlet plan A3:
// no second hand-copied map; the NixOS module hands the app a store copy of
// the same file).
//
// Columns (see the TSV header):
//
//	system collection core emulator extensions sky bucket torrent
//
// Add or remove a system by editing the TSV row; every consumer follows.
package catalogue

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// notApplicable is the TSV's "-" marker for a null column.
const notApplicable = "-"

// System is one catalogue row. Key is the directory key under the bucket
// root (nes, snes, …, 3ds) and the Pegasus shortname; Collection is the
// display title; Bucket routes the system to its games tree
// (cartridge/optical/modern); SkyHandle is Skyscraper's -p platform handle
// when it differs from Key; Extensions are ROM file extensions without dots
// (case-insensitively matched by HasROMExtension).
type System struct {
	Key        string
	Collection string
	Core       string // "" when Emulator is set (Wii U → cemu)
	Emulator   string // "" when Core is set
	Extensions []string
	SkyHandle  string // "" when identical to Key
	Bucket     string // cartridge | optical | modern
	Torrent    string // Minerva/Myrient torrent basename, "" when N/A
}

// orEmpty maps the TSV "-" marker to the empty string.
func orEmpty(v string) string {
	if v == notApplicable {
		return ""
	}
	return v
}

// Load parses the catalogue TSV at path. Rows keep file order (the fleet's
// canonical system ordering — the dashboard card wall uses it).
func Load(path string) ([]System, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("catalogue: open %s: %w", path, err)
	}
	defer f.Close() //nolint:errcheck // read-only

	var systems []System
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024) // torrent names are long but bounded
	lineNo := 0
	for sc.Scan() {
		lineNo++
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		cols := strings.Split(line, "\t")
		if len(cols) != 8 {
			return nil, fmt.Errorf("catalogue: %s:%d: %d columns, want 8: %q",
				filepath.Base(path), lineNo, len(cols), line)
		}
		for i := range cols {
			cols[i] = strings.TrimSpace(cols[i])
		}
		s := System{
			Key:        cols[0],
			Collection: cols[1],
			Core:       orEmpty(cols[2]),
			Emulator:   orEmpty(cols[3]),
			Extensions: strings.Split(orEmpty(cols[4]), ","),
			SkyHandle:  orEmpty(cols[5]),
			Bucket:     cols[6],
			Torrent:    orEmpty(cols[7]),
		}
		if s.Extensions[0] == "" {
			s.Extensions = nil
		}
		if s.Key == "" || s.Collection == "" || s.Bucket == "" {
			return nil, fmt.Errorf("catalogue: %s:%d: empty system/collection/bucket column", path, lineNo)
		}
		systems = append(systems, s)
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("catalogue: read %s: %w", path, err)
	}
	if len(systems) == 0 {
		return nil, errors.New("catalogue: no systems parsed")
	}
	return systems, nil
}

// HasROMExtension reports whether name's extension is one of the system's
// ROM extensions, case-insensitively (mirrors arcade-inventory's -iregex
// match and cartridge-scrape.sh's global regex).
func (s System) HasROMExtension(name string) bool {
	ext := strings.TrimPrefix(filepath.Ext(name), ".")
	if ext == "" {
		return false
	}
	ext = strings.ToLower(ext)
	for _, e := range s.Extensions {
		if strings.ToLower(e) == ext {
			return true
		}
	}
	return false
}

// SkyPlatform returns the Skyscraper -p handle for the system: the
// skyHandle column when set (ps1→psx, pokemonmini→pokemini, …), else the
// system key. The resource cache lives at <cacheDir>/<SkyPlatform>/.
func (s System) SkyPlatform() string {
	if s.SkyHandle != "" {
		return s.SkyHandle
	}
	return s.Key
}

// ByBucket splits systems into the three games-tree buckets, keeping order.
func ByBucket(systems []System) (cartridge, optical, modern []System) {
	for _, s := range systems {
		switch s.Bucket {
		case "cartridge":
			cartridge = append(cartridge, s)
		case "optical":
			optical = append(optical, s)
		case "modern":
			modern = append(modern, s)
		}
	}
	return cartridge, optical, modern
}
