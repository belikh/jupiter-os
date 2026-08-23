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
	"archive/zip"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/catalogue"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/exo"
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
	ExoRoot            string // eXo curated collections root (P8 import); "" disables
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
	// eXo curated-collection import (P8): systems/games/art counts from
	// the read-only metadata parse (0 when no exo root is configured).
	ExoSystems int
	ExoGames   int64
	ExoArt     int64
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
		if walkErr == nil {
			// nil error covers both a real walk and an absent dir (nil
			// games): absent = system not populated → zero games, and
			// stale rows for a deliberately removed dir go with it.
			if err := s.st.ReplaceSystemGames(sys.Key, games, seen); err != nil {
				res.Errors++
				res.Warnings = append(res.Warnings, fmt.Sprintf("%s: persist games: %v", sys.Key, err))
			} else if len(games) > 0 {
				// P6 carry-in: persist each game file's SHA1 (the
				// scanner's own CacheID) so the launcher-DB/library
				// surfaces can show it. Best-effort: hashing failures
				// become warnings, never scan errors.
				s.persistSHA1s(sys, filepath.Join(s.cfg.bucketRoot(sys.Bucket), sys.Key), &res)
			}
		} else {
			// Any walk error (unmounted bucket, permission shift, a dir
			// vanishing mid-walk): DO NOT replace — ReplaceSystemGames
			// would prune every row the failed walk didn't see, wiping
			// the hidden/verify_state/first_seen the schema promises
			// rescans preserve (ADV-P1-03). Keep the previous rows,
			// surface the failure loudly.
			res.Warnings = append(res.Warnings,
				fmt.Sprintf("%s: ROM walk failed, kept previous rows: %v", sys.Key, walkErr))
		}
		for _, g := range games {
			res.Games++
			res.Bytes += g.SizeBytes
		}

		// 3. DAT currency: <datDir>/<sys>.dat header.
		datPath := filepath.Join(s.cfg.DATDir, sys.Key+".dat")
		if info, err := ReadDAT(datPath); err == nil {
			info.SystemKey = sys.Key
			if err := s.st.SetDATInfo(*info); err != nil {
				res.Warnings = append(res.Warnings, fmt.Sprintf("%s: persist dat: %v", sys.Key, err))
			}
		} else if !errors.Is(err, fs.ErrNotExist) {
			res.Warnings = append(res.Warnings, fmt.Sprintf("%s: dat: %v", sys.Key, err))
		}

		// 4. Skyscraper cache coverage: <cacheDir>/<sys.Key>/db.xml —
		// keyed on the catalogue key (cartridge-scrape.sh's
		// $CACHE_DIR/$platform; the -p SkyHandle is NOT the cache key,
		// ADV-P5-01).
		entries, err := countCacheGames(filepath.Join(s.cfg.SkyscraperCacheDir, sys.Key))
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

	// 6. eXo curated collections (P8): read-only import of the kiosk-
	// generated metadata files into source=exo systems. Absent root or
	// absent per-collection files are normal; per-collection parse
	// failures become warnings and keep the previous rows.
	if s.cfg.ExoRoot != "" {
		er := exo.Import(s.st, s.cfg.ExoRoot)
		res.ExoSystems = len(er.Imported)
		res.ExoGames = er.Games
		res.ExoArt = er.Art
		res.Warnings = append(res.Warnings, er.Warnings...)
	}

	// 7. Incoming staging summary — per system (files/bytes/aria2-control
	// presence, the verify page's "staged" column) plus the whole-tree
	// totals for the status strip. Persisted at scan time only: a live
	// walk of a multi-TB staged tree on every 2s poll would hammer
	// europa's HDD (R5); the verify runner itself re-checks .aria2
	// presence authoritatively at run time.
	var staging []store.StagingRow
	for _, sys := range systems {
		files, bytes := countTree(filepath.Join(s.cfg.IncomingDir, sys.Key))
		staging = append(staging, store.StagingRow{
			SystemKey: sys.Key, Files: files, Bytes: bytes,
			InFlight: hasAria2Control(filepath.Join(s.cfg.IncomingDir, sys.Key)),
		})
	}
	if err := s.st.ReplaceStaging(staging); err != nil {
		res.Warnings = append(res.Warnings, "staging persist: "+err.Error())
	}
	res.IncomingFiles, res.IncomingBytes = countTree(s.cfg.IncomingDir)
	_ = s.st.SetMeta("incoming_files", strconv.FormatInt(res.IncomingFiles, 10))
	_ = s.st.SetMeta("incoming_bytes", strconv.FormatInt(res.IncomingBytes, 10))

	return res
}

// hasAria2Control reports whether any *.aria2 control file exists under
// dir (a download is mid-flight for that tree). Absent dir = false.
func hasAria2Control(dir string) bool {
	found := false
	_ = filepath.WalkDir(dir, func(_ string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil // unreadable entries skipped, like find 2>/dev/null
		}
		if !d.IsDir() && strings.HasSuffix(d.Name(), ".aria2") {
			found = true
			return filepath.SkipAll
		}
		return nil
	})
	return found
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

// persistSHA1s fills games.sha1 for the system's rows that lack one
// (P6 carry-in), using CacheID — the same id the coverage matcher keys
// on. Semantics:
//
//   - Fill-ONCE: only rows with sha1 IS NULL are hashed, so a repeat
//     scan never re-walks bytes it already knows (europa's HDD budget,
//     plan R5). A file whose CONTENT changes under an unchanged path
//     keeps its recorded id until a checksum-bearing igir report
//     overwrites it via SetGameChecksums — sha1 here is a display fact;
//     verify ingest is the authority.
//   - Files above romHashSizeLimit stay NULL (CacheID's own cap — same
//     false-negative direction ApplyCacheFlags accepts).
func (s *Scanner) persistSHA1s(sys catalogue.System, sysDir string, res *Result) {
	missing, err := s.st.GamesMissingSHA1(sys.Key)
	if err != nil || len(missing) == 0 {
		if err != nil {
			res.Warnings = append(res.Warnings, fmt.Sprintf("%s: sha1 lookup: %v", sys.Key, err))
		}
		return
	}
	cks := make([]store.GameChecksum, 0, len(missing))
	skipped := 0
	for _, rel := range missing {
		id, err := CacheID(filepath.Join(sysDir, rel))
		if err != nil {
			skipped++ // oversized/unreadable: stays NULL (documented miss)
			continue
		}
		cks = append(cks, store.GameChecksum{RelPath: rel, SHA1: id})
	}
	if len(cks) > 0 {
		if err := s.st.SetGameChecksums(sys.Key, cks); err != nil {
			res.Warnings = append(res.Warnings, fmt.Sprintf("%s: persist sha1: %v", sys.Key, err))
			return
		}
	}
	if skipped > 0 {
		log.Printf("scanner: %s: %d game file(s) not hashed for sha1 (size/read limits)", sys.Key, skipped)
	}
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

// ReadDAT streams a Logiqx datafile: header fields + <game> count, without
// holding the whole DAT in memory (No-Intro sets reach tens of MB).
// Exported for the DAT manager (P3), which re-parses a freshly fetched
// DAT so the currency card updates without waiting for a full rescan.
func ReadDAT(path string) (*store.DATInfo, error) {
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

// countCacheGames implements the Skyscraper coverage heuristic via
// ReadCacheCoverage (P5 refactored the raw counter out so the scrape
// driver and the coverage tracker share one parser).
func countCacheGames(cacheDir string) (int64, error) {
	cc, err := ReadCacheCoverage(cacheDir)
	if err != nil {
		return 0, err
	}
	return cc.Entries, nil
}

// ---- P5: shared Skyscraper-cache parsing -----------------------------------

// CacheCoverage is the parsed shape of one platform's Skyscraper resource
// cache (<cacheDir>/db.xml — see Skyscraper's CACHE.md: a flat list of
// <resource id=".." type=".." source=".."> elements keyed by ROM hash).
//
// Entries counts DISTINCT ids (the P1 presence-level number); Descriptions
// / Covers count distinct ids holding at least one resource of type
// "description" / "cover" (the P5 coverage tracker's headline split). The
// ID sets are exported so per-game mapping (CacheID + ApplyCacheFlags)
// runs off the SAME single parse; DescriptionsByID carries the actual
// description TEXT per id (first resource wins) so the P7 enrichment
// ingest can fill games.description from exactly what the cache holds —
// never invented, never padded.
type CacheCoverage struct {
	Entries         int64
	Descriptions    int64
	Covers          int64
	DescIDs         map[string]struct{}
	CoverIDs        map[string]struct{}
	DescriptionsIDs map[string]string // id → description text
}

// ReadCacheCoverage parses <cacheDir>/db.xml. An absent db.xml reads as a
// zero-value coverage (not an error — an unscraped platform); a corrupt
// one is an error the caller records as a warning.
func ReadCacheCoverage(cacheDir string) (*CacheCoverage, error) {
	path := filepath.Join(cacheDir, "db.xml")
	f, err := os.Open(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return &CacheCoverage{}, nil
		}
		return nil, err
	}
	defer f.Close() //nolint:errcheck // read-only

	cc := &CacheCoverage{
		DescIDs:         map[string]struct{}{},
		CoverIDs:        map[string]struct{}{},
		DescriptionsIDs: map[string]string{},
	}
	ids := map[string]struct{}{}
	dec := xml.NewDecoder(f)
	for {
		tok, err := dec.Token()
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return nil, fmt.Errorf("scanner: parse %s: %w", path, err)
		}
		if se, ok := tok.(xml.StartElement); ok && se.Name.Local == "resource" {
			var id, typ string
			for _, a := range se.Attr {
				switch a.Name.Local {
				case "id":
					id = a.Value
				case "type":
					typ = a.Value
				}
			}
			if id == "" {
				continue
			}
			if _, seen := ids[id]; !seen {
				ids[id] = struct{}{}
				cc.Entries++
			}
			// Type strings verified against europa-produced caches and the
			// committed fixtures: textual metadata is "description", box art
			// is "cover". Unknown types simply contribute to Entries only.
			switch typ {
			case "description":
				if _, seen := cc.DescIDs[id]; !seen {
					cc.DescIDs[id] = struct{}{}
					cc.Descriptions++
				}
				// The element's chardata IS the description text the cache
				// holds. First resource wins (Skyscraper keeps one per
				// source; we never merge prose). Whitespace-only text does
				// not count as ingested enrichment.
				if _, seen := cc.DescriptionsIDs[id]; !seen {
					var text string
					if err := dec.DecodeElement(&text, &se); err == nil &&
						strings.TrimSpace(text) != "" {
						cc.DescriptionsIDs[id] = text
					}
				}
			case "cover":
				if _, seen := cc.CoverIDs[id]; !seen {
					cc.CoverIDs[id] = struct{}{}
					cc.Covers++
				}
			}
		}
	}
	return cc, nil
}

// romHashSizeLimit caps what CacheID will hash: multi-hundred-MB optical
// images would stall the coverage recompute on europa's HDD for a
// best-effort flag. Files above the cap stay unflagged (false negative,
// never a false positive). A var, not a const, so tests can shrink it.
var romHashSizeLimit int64 = 512 << 20 // 512 MiB

// ErrROMTooLarge reports that a game file exceeded romHashSizeLimit and
// was therefore left unmapped (errors.Is-able).
var ErrROMTooLarge = errors.New("scanner: rom exceeds hashing size limit")

// CacheID computes Skyscraper's cache id for a game FILE: the lowercase
// hex SHA1 of its contents (40 chars — the shape every committed cache
// fixture shows). For .zip archives (No-Intro cartridge sets ship as
// zips) the SHA1 of the FIRST regular entry's decompressed contents is
// used, matching Skyscraper's inside-the-archive keying closely enough
// for a best-effort flag.
//
// TRAP (documented, accepted): Skyscraper has varied its archive keying
// across versions (inner CRC32 vs SHA1, first-entry heuristics). A wrong
// id here can only MISS a cache hit — flags stay false (a false NEGATIVE
// the drill-down treats as "uncovered"), and can never falsely claim a
// game is covered. Oversized files return ErrROMTooLarge (id ""), also a
// false negative. Never wire a consumer to this that cannot tolerate a miss.
func CacheID(path string) (string, error) {
	info, err := os.Stat(path)
	if err != nil {
		return "", err
	}
	if info.Size() > romHashSizeLimit {
		return "", fmt.Errorf("scanner: %s: %w", filepath.Base(path), ErrROMTooLarge)
	}
	h := sha1.New()
	if strings.EqualFold(filepath.Ext(path), ".zip") {
		zr, err := zip.OpenReader(path)
		if err != nil {
			return "", fmt.Errorf("scanner: zip %s: %w", filepath.Base(path), err)
		}
		defer zr.Close() //nolint:errcheck // read-only
		for _, zf := range zr.File {
			if zf.FileInfo().IsDir() {
				continue
			}
			rc, err := zf.Open()
			if err != nil {
				return "", fmt.Errorf("scanner: zip entry %s/%s: %w", filepath.Base(path), zf.Name, err)
			}
			_, cerr := io.Copy(h, rc)
			closeErr := rc.Close()
			if cerr != nil {
				return "", fmt.Errorf("scanner: zip entry %s/%s: %w", filepath.Base(path), zf.Name, cerr)
			}
			if closeErr != nil {
				return "", closeErr
			}
			return hex.EncodeToString(h.Sum(nil)), nil
		}
		return "", fmt.Errorf("scanner: zip %s holds no entries", filepath.Base(path))
	}
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close() //nolint:errcheck // read-only
	if _, err := io.Copy(h, f); err != nil {
		return "", fmt.Errorf("scanner: hash %s: %w", filepath.Base(path), err)
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// CacheDirFor maps a persisted system row onto its Skyscraper platform
// cache directory: <cacheRoot>/<sys.Key> — the CATALOGUE key, matching
// cartridge-scrape.sh's platform_cache="$CACHE_DIR/$platform" and the live
// europa caches (ps1, gamecube, pokemonmini, dsi, new3ds, sms, sg1000,
// a2600). The SkyHandle is only the -p handle; keying the dir on it made
// every diverging system miss its cache and collided 3ds/new3ds on the
// shared "3ds" handle (ADV-P5-01).
func CacheDirFor(cacheRoot string, sys store.SystemRow) string {
	return filepath.Join(cacheRoot, sys.Key)
}

// ApplyCacheFlags recomputes one system's scrape coverage after a run
// (gauntlet plan §2 P5): the scrape_coverage aggregate is refreshed from
// a single ReadCacheCoverage parse of the platform's db.xml, and each
// game row's has_description/has_cover flips best-effort from cache
// presence — the game file's CacheID appearing among the description /
// cover resource ids. Games whose files cannot be keyed (oversized,
// unreadable, zip-keying mismatch) stay false; the flags are a coverage
// HINT, never an authority. Full-replace semantics (SetSystemScrapeFlags),
// so a wiped cache clears every flag.
//
// sysDir is the system's games-tree directory (files are hashed there);
// cacheDir is the PLATFORM cache dir (CacheDirFor).
func ApplyCacheFlags(st *store.Store, sys store.SystemRow, sysDir, cacheDir string) error {
	cc, err := ReadCacheCoverage(cacheDir)
	if err != nil {
		return fmt.Errorf("scanner: coverage %s: %w", sys.Key, err)
	}
	if err := st.SetScrapeCoverage(sys.Key, cc.Entries); err != nil {
		return fmt.Errorf("scanner: coverage persist %s: %w", sys.Key, err)
	}
	page, err := st.ListGames(store.GameListOpts{SystemKey: sys.Key})
	if err != nil {
		return fmt.Errorf("scanner: games %s: %w", sys.Key, err)
	}
	// Nothing to match against (or no games): clear and stop — no hashing.
	if len(cc.DescIDs)+len(cc.CoverIDs) == 0 || len(page.Games) == 0 {
		return st.SetSystemScrapeFlags(sys.Key, nil)
	}
	flags := make([]store.GameScrapeFlag, 0, len(page.Games))
	skipped := 0
	for _, g := range page.Games {
		id, err := CacheID(filepath.Join(sysDir, g.RelPath))
		if err != nil {
			skipped++ // oversized/unreadable: flag stays false (documented miss)
			continue
		}
		_, desc := cc.DescIDs[id]
		_, cover := cc.CoverIDs[id]
		if desc || cover {
			flags = append(flags, store.GameScrapeFlag{RelPath: g.RelPath, Description: desc, Cover: cover})
		}
	}
	if skipped > 0 {
		log.Printf("scanner: %s: %d game file(s) not keyed for coverage (size/read limits)", sys.Key, skipped)
	}
	return st.SetSystemScrapeFlags(sys.Key, flags)
}

// maxIngestDescription bounds ONE cache-ingested description (ADV-P7-04):
// a pathological db.xml resource would otherwise persist multi-MB prose
// that rides into every generated launcher-DB line. Generous for real
// metadata (the longest legitimate game blurb is a few hundred chars);
// rune-bounded so the cut never splits a codepoint.
const maxIngestDescription = 4000

// ApplyCacheEnrichment fills games.description from the platform cache
// after a scrape run (P7 / P6-critic carry-in: enrichment demonstrated
// END TO END — cache → store → generated metadata). Each visible game's
// CacheID is looked up among the db.xml description resources; the
// resource TEXT is persisted verbatim via SetGameMeta (selective write:
// only non-empty values land, so an id-less pass can never wipe a stored
// description), bounded by maxIngestDescription chars (ADV-P7-04 — a
// pathological cache entry would otherwise ride into every launcher-DB
// line as multi-MB prose; the bound truncates at a rune boundary and is
// logged ONCE per run, not per game). Honesty contract: the generator
// emits exactly what this ingested — no placeholder prose, no synthesis
// from titles.
//
// Returns the number of games whose description was set/refreshed.
func ApplyCacheEnrichment(st *store.Store, sys store.SystemRow, sysDir, cacheDir string) (int, error) {
	cc, err := ReadCacheCoverage(cacheDir)
	if err != nil {
		return 0, fmt.Errorf("scanner: enrichment %s: %w", sys.Key, err)
	}
	if len(cc.DescriptionsIDs) == 0 {
		return 0, nil
	}
	page, err := st.ListGames(store.GameListOpts{SystemKey: sys.Key})
	if err != nil {
		return 0, fmt.Errorf("scanner: enrichment games %s: %w", sys.Key, err)
	}
	metas := make([]store.GameMeta, 0, len(page.Games))
	truncated := 0
	for _, g := range page.Games {
		id, err := CacheID(filepath.Join(sysDir, g.RelPath))
		if err != nil {
			continue // oversized/unreadable: stays unenriched (documented miss)
		}
		if text, ok := cc.DescriptionsIDs[id]; ok {
			text = strings.TrimSpace(text)
			if r := []rune(text); len(r) > maxIngestDescription {
				text = string(r[:maxIngestDescription])
				truncated++
			}
			metas = append(metas, store.GameMeta{RelPath: g.RelPath, Description: text})
		}
	}
	if truncated > 0 {
		log.Printf("scanner: %s: %d description(s) exceeded %d chars — truncated at ingest",
			sys.Key, truncated, maxIngestDescription)
	}
	if len(metas) == 0 {
		return 0, nil
	}
	if err := st.SetGameMeta(sys.Key, metas); err != nil {
		return 0, fmt.Errorf("scanner: enrichment persist %s: %w", sys.Key, err)
	}
	return len(metas), nil
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
