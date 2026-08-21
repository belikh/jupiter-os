// Package scanner walks europa's retro trees and persists what it finds
// into the webapp's SQLite store: the console-system catalogue
// (scripts/cartridge-catalogue.tsv semantics), per-system ROM counts and
// sizes across the three games buckets, DAT currency (Logiqx header date
// per system), Skyscraper cache coverage, the legacy arcade-inventory
// JSON (transition aid, absence tolerated), and a summary of the aria2
// incoming staging tree. One Scan is one row in the runs table.
//
// Design notes for europa's 2-core/HDD budget (plan R5): the walk stats
// every file once per scan (no hashing), runs at startup and on demand
// (never on a hot timer), and a second concurrent Scan is rejected while
// one is in flight.
package scanner

import (
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/catalogue"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// ErrBusy is returned when a scan is requested while one is running.
var ErrBusy = errors.New("scanner: a scan is already running")

// Config points at the trees to scan. Every path is optional at runtime
// (missing dirs read as empty) so the same code runs against europa's pool
// layout and the VM test fixture tree.
type Config struct {
	CatalogueTsv       string
	CartridgeRoot      string
	OpticalRoot        string
	ModernRoot         string
	DATDir             string
	SkyscraperCacheDir string
	IncomingDir        string
	InventoryFile      string
	DBPath             string // informational (logging); store is injected
}

// bucketRoot maps a catalogue bucket to its configured games root.
func (c Config) bucketRoot(bucket string) string {
	switch bucket {
	case "optical":
		return c.OpticalRoot
	case "modern":
		return c.ModernRoot
	default:
		return c.CartridgeRoot
	}
}

// Result summarizes one completed scan.
type Result struct {
	Systems       int
	Games         int64
	Bytes         int64
	IncomingFiles int64
	IncomingBytes int64
	Errors        int
	Warnings      []string
}

// State is the in-memory scan status the dashboard polls.
type State struct {
	Running   bool
	StartedAt string
	LastOKAt  string
	LastError string
}

// Scanner owns scan execution and serialization.
type Scanner struct {
	cfg Config
	st  *store.Store
	mu  sync.Mutex
	// state (guarded by mu) carries the live scan indicator; the runs
	// table in the store is the durable record.
	state State
}

// New builds a Scanner over an opened store.
func New(cfg Config, st *store.Store) *Scanner {
	return &Scanner{cfg: cfg, st: st}
}

// State returns the current in-memory scan status.
func (s *Scanner) State() State {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.state
}

// Scan runs one full pipeline scan. It returns ErrBusy if a scan is
// already in flight; per-system read errors become warnings, not failures
// (a pool with one unmounted bucket still scans the rest — matching the
// per-platform resilience of cartridge-scrape.sh).
func (s *Scanner) Scan() (Result, error) {
	s.mu.Lock()
	if s.state.Running {
		s.mu.Unlock()
		return Result{}, ErrBusy
	}
	s.state.Running = true
	s.state.StartedAt = time.Now().UTC().Format(time.RFC3339)
	s.state.LastError = ""
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		s.state.Running = false
		s.mu.Unlock()
	}()

	runID, err := s.st.StartRun("scan")
	if err != nil {
		return Result{}, fmt.Errorf("scanner: record run: %w", err)
	}

	res := s.scanAll()

	status := "ok"
	if res.Errors > 0 {
		status = "error" // warnings are recorded in detail, they don't fail the run
	}
	detail, _ := json.Marshal(res)
	if err := s.st.FinishRun(runID, status, string(detail)); err != nil {
		return res, fmt.Errorf("scanner: finish run: %w", err)
	}

	s.mu.Lock()
	if status == "ok" {
		s.state.LastOKAt = time.Now().UTC().Format(time.RFC3339)
	} else {
		s.state.LastError = fmt.Sprintf("%d errors during scan", res.Errors)
	}
	s.mu.Unlock()
	return res, nil
}
func (s *Scanner) scanAll() Result {
	var res Result

	systems, err := catalogue.Load(s.cfg.CatalogueTsv)
	if err != nil {
		res.Errors++
		res.Warnings = append(res.Warnings, err.Error())
		return res
	}

	// 1. Catalogue → systems table (extensions JSON for later phases).
	var rows []store.SystemRow
	for i, sys := range systems {
		ext, _ := json.Marshal(sys.Extensions)
		rows = append(rows, store.SystemRow{
			Key: sys.Key, Collection: sys.Collection, Bucket: sys.Bucket,
			Core: sys.Core, Emulator: sys.Emulator, SkyHandle: sys.SkyHandle,
			Torrent: sys.Torrent, Extensions: string(ext), SortOrder: i + 1,
		})
	}
	if err := s.st.UpsertSystems(rows); err != nil {
		res.Errors++
		res.Warnings = append(res.Warnings, "systems import: "+err.Error())
		return res
	}
	res.Systems = len(systems)

	seen := time.Now().UTC()
	for _, sys := range systems {
		// 2. ROM walk: <bucketRoot>/<sys>/ recursively. One row per GAME
		// (extension match or zip), companion bytes attributed — see
		// scanSystemDir.
		games, walkErr := scanSystemDir(filepath.Join(s.cfg.bucketRoot(sys.Bucket), sys.Key), sys)
		if walkErr != nil && !errors.Is(walkErr, fs.ErrNotExist) {
			res.Warnings = append(res.Warnings, fmt.Sprintf("%s: ROM walk: %v", sys.Key, walkErr))
		}
		if err := s.st.ReplaceSystemGames(sys.Key, games, seen); err != nil {
			res.Errors++
			res.Warnings = append(res.Warnings, fmt.Sprintf("%s: persist games: %v", sys.Key, err))
		}
		for _, g := range games {
			res.Games++
			res.Bytes += g.SizeBytes
		}

		// 3. DAT currency: <datDir>/<sys>.dat header.
		datPath := filepath.Join(s.cfg.DATDir, sys.Key+".dat")
		if info, err := readDAT(datPath); err == nil {
			info.SystemKey = sys.Key
			if err := s.st.SetDATInfo(*info); err != nil {
				res.Warnings = append(res.Warnings, fmt.Sprintf("%s: persist dat: %v", sys.Key, err))
			}
		} else if !errors.Is(err, fs.ErrNotExist) {
			res.Warnings = append(res.Warnings, fmt.Sprintf("%s: dat: %v", sys.Key, err))
		}

		// 4. Skyscraper cache coverage: <cacheDir>/<skyPlatform>/db.xml.
		entries, err := countCacheGames(filepath.Join(s.cfg.SkyscraperCacheDir, sys.SkyPlatform()))
		if err != nil {
			res.Warnings = append(res.Warnings, fmt.Sprintf("%s: cache: %v", sys.Key, err))
		} else if err := s.st.SetScrapeCoverage(sys.Key, entries); err != nil {
			res.Warnings = append(res.Warnings, fmt.Sprintf("%s: persist coverage: %v", sys.Key, err))
		}
	}

	// 5. Legacy inventory import (absent file tolerated).
	invRows, invAt, err := readInventory(s.cfg.InventoryFile)
	if err != nil {
		res.Warnings = append(res.Warnings, "inventory: "+err.Error())
	} else {
		for i := range invRows {
			invRows[i].GeneratedAt = invAt
		}
		if err := s.st.ReplaceInventory(invRows); err != nil {
			res.Warnings = append(res.Warnings, "inventory persist: "+err.Error())
		}
	}

	// 6. Incoming staging summary (whole tree, all buckets) — persisted in
	// meta for the status strip (runs.detail holds the full JSON).
	res.IncomingFiles, res.IncomingBytes = countTree(s.cfg.IncomingDir)
	_ = s.st.SetMeta("incoming_files", strconv.FormatInt(res.IncomingFiles, 10))
	_ = s.st.SetMeta("incoming_bytes", strconv.FormatInt(res.IncomingBytes, 10))

	return res
}

// scanSystemDir walks one system's directory tree and returns one GameRow
// per GAME (not per file), mirroring the pipeline's file semantics
// (cartridge-scrape.sh): a game is a file matching the system's ROM
// extensions OR a .zip archive — No-Intro cartridge sets ship as zips (the
// verify COPY has no extract, so archives land in the tree as-is) and
// cartridge-scrape.sh's global regex adds zip for exactly that reason.
// Companion files — .bin tracks beside a .cue/.gdi, or any other non-dot
// file — do not create games; their bytes are attributed to the game they
// travel with so per-system sizes match what a du -sb of the tree reports:
//   - companions in a directory holding exactly ONE game → that game;
//   - otherwise a companion goes to the game whose base name (extension
//     stripped) is a prefix of the companion's ("Game (USA) (Track 1).bin"
//     → "Game (USA).cue"; longest such prefix wins);
//   - unattributed companions are skipped (still on disk, just counted in
//     no game — e.g. a stray notes.txt among many games).
//
// Dotfiles never count in either role. Rows come back sorted by path.
// A missing dir is (nil, nil): "system not populated", not an error —
// any other walk error returns (nil, err) and the caller must NOT prune
// the system's existing rows with a replace (see scanAll).
func scanSystemDir(dir string, sys catalogue.System) ([]store.GameRow, error) {
	type found struct {
		rel  string
		size int64
	}
	var games, companions []found
	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		name := d.Name()
		if strings.HasPrefix(name, ".") {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(dir, path)
		if err != nil {
			return err
		}
		f := found{rel: rel, size: info.Size()}
		if sys.HasROMExtension(name) || strings.EqualFold(filepath.Ext(name), ".zip") {
			games = append(games, f)
		} else {
			companions = append(companions, f)
		}
		return nil
	})
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, nil // system dir absent: not populated, not an error
		}
		return nil, err
	}

	// Attribute companion bytes to games, per directory.
	gamesInDir := map[string][]int{} // dir rel path → indexes into games
	for i, g := range games {
		d := filepath.Dir(g.rel)
		gamesInDir[d] = append(gamesInDir[d], i)
	}
	stripExt := func(p string) string { return strings.TrimSuffix(p, filepath.Ext(p)) }
	for _, c := range companions {
		idx := gamesInDir[filepath.Dir(c.rel)]
		best, bestLen := -1, -1
		if len(idx) == 1 {
			best = idx[0]
		} else {
			// Multiple games share the dir: longest-prefix basename wins.
			base := stripExt(c.rel)
			for _, i := range idx {
				if gb := stripExt(games[i].rel); strings.HasPrefix(base, gb) && len(gb) > bestLen {
					best, bestLen = i, len(gb)
				}
			}
		}
		if best >= 0 {
			games[best].size += c.size
		}
	}

	rows := make([]store.GameRow, len(games))
	for i, g := range games {
		rows[i] = store.GameRow{RelPath: g.rel, SizeBytes: g.size}
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].RelPath < rows[j].RelPath })
	return rows, nil
}

// logiqxHeader captures the Logiqx <datafile><header> fields the DAT
// currency card needs. Field tags are relative to the <header> element
// (readDAT DecodeElements the header subtree itself); <date> is the
// currency timestamp, <build> the clrmamepro-style fallback.
type logiqxHeader struct {
	Name    string `xml:"name"`
	Version string `xml:"version"`
	Date    string `xml:"date"`
	Build   string `xml:"build"`
}

// readDAT streams a Logiqx datafile: header fields + <game> count, without
// holding the whole DAT in memory (No-Intro sets reach tens of MB).
func readDAT(path string) (*store.DATInfo, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err // wrapped fs.ErrNotExist propagates
	}
	defer f.Close() //nolint:errcheck // read-only

	info := &store.DATInfo{Filename: filepath.Base(path)}
	if st, err := f.Stat(); err == nil {
		info.SizeBytes = st.Size()
		info.ModTime = st.ModTime()
	}

	dec := xml.NewDecoder(f)
	var header logiqxHeader
	for {
		tok, err := dec.Token()
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return nil, fmt.Errorf("scanner: parse %s: %w", path, err)
		}
		switch t := tok.(type) {
		case xml.StartElement:
			switch t.Name.Local {
			case "header":
				// DecodeElement consumes through </header> in one go.
				if err := dec.DecodeElement(&header, &t); err != nil {
					return nil, fmt.Errorf("scanner: header of %s: %w", path, err)
				}
			case "game":
				info.RomCount++
			}
		}
	}
	info.DatName = header.Name
	info.Version = header.Version
	info.Date = header.Date
	if info.Date == "" {
		info.Date = header.Build // clrmamepro-style DATs put the date in <build>
	}
	return info, nil
}

// countCacheGames implements the Skyscraper coverage heuristic: a game
// counts as covered when its db.xml holds at least one <resource> entry
// for the game's unique id (see Skyscraper's CACHE.md — the cache is a
// flat list of <resource id=".." type=".." source=".."> elements keyed by
// ROM hash). We count DISTINCT ids: per-type coverage (art/desc/video
// separately) is P5's coverage tracker, this is the P1 presence-level
// number. An absent cache dir reads as 0 (not an error); a corrupt db.xml
// is an error the scan records as a warning.
func countCacheGames(cacheDir string) (int64, error) {
	path := filepath.Join(cacheDir, "db.xml")
	f, err := os.Open(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return 0, nil
		}
		return 0, err
	}
	defer f.Close() //nolint:errcheck // read-only

	dec := xml.NewDecoder(f)
	ids := map[string]struct{}{}
	for {
		tok, err := dec.Token()
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return 0, fmt.Errorf("scanner: parse %s: %w", path, err)
		}
		if se, ok := tok.(xml.StartElement); ok && se.Name.Local == "resource" {
			for _, a := range se.Attr {
				if a.Name.Local == "id" {
					ids[a.Value] = struct{}{}
					break
				}
			}
		}
	}
	return int64(len(ids)), nil
}

// size mirrors one inventory JSON per-system entry.
type size struct {
	Count     int64 `json:"count"`
	SizeBytes int64 `json:"size_bytes"`
}

// readInventory parses the legacy inventory JSON if present. Absent file:
// (nil, "", nil). Present but unparseable: error (recorded as warning).
func readInventory(path string) ([]store.InventoryRow, string, error) {
	if path == "" {
		return nil, "", nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, "", nil // transition aid: absence tolerated
		}
		return nil, "", err
	}
	var raw struct {
		GeneratedAt string          `json:"generated_at"`
		Cartridge   map[string]size `json:"cartridge"`
		Optical     map[string]size `json:"optical"`
		Modern      map[string]size `json:"modern"`
	}
	if err := json.Unmarshal(b, &raw); err != nil {
		return nil, "", fmt.Errorf("parse %s: %w", path, err)
	}
	byBucket := map[string]map[string]size{
		"cartridge": raw.Cartridge, "optical": raw.Optical, "modern": raw.Modern,
	}
	var rows []store.InventoryRow
	for _, bucket := range []string{"cartridge", "optical", "modern"} {
		keys := make([]string, 0, len(byBucket[bucket]))
		for k := range byBucket[bucket] {
			keys = append(keys, k)
		}
		sort.Strings(keys) // stable row order
		for _, k := range keys {
			v := byBucket[bucket][k]
			rows = append(rows, store.InventoryRow{SystemKey: k, Count: v.Count, SizeBytes: v.SizeBytes})
		}
	}
	return rows, raw.GeneratedAt, nil
}

// countTree sums file count + bytes under root (absent root: zeros).
func countTree(root string) (files, bytes int64) {
	_ = filepath.WalkDir(root, func(_ string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil // unreadable entries are skipped, not fatal
		}
		if d.IsDir() {
			return nil
		}
		if info, err := d.Info(); err == nil {
			files++
			bytes += info.Size()
		}
		return nil
	})
	return files, bytes
}

// AgeDays returns whole days between date and now; -1 when unparseable
// (rendered as unknown). Shared with the web layer so the DAT-currency
// chip and the scanner agree on one parser. Layouts seen in the wild:
// plain Logiqx dates, the Fresh1G1R McLean family ("2026-06-22 07-44-23",
// space separator + dash time), its colon variant, clrmamepro dd/mm/yyyy,
// and RFC3339.
func AgeDays(date string, now time.Time) int {
	layouts := []string{
		"2006-01-02",
		"2006-01-02 15-04-05", // Fresh1G1R McLean 1G1R (ADV-P1-02)
		"2006-01-02 15:04:05", // colon-time variant, defensively
		"2006-01-02T15:04:05",
		"02/01/2006",
		time.RFC3339,
	}
	for _, layout := range layouts {
		if t, err := time.Parse(layout, date); err == nil {
			return int(now.Sub(t).Hours() / 24)
		}
	}
	return -1
}
