// Package store is the arcade webapp's SQLite persistence layer
// (ADR-0002 D3): one database file under the retro state dir, WAL mode,
// pure-Go modernc.org/sqlite driver (no cgo — the package substitutes
// cleanly from cache.nixos.org on every host). Single writer on a single
// host; the webapp serializes pipeline jobs around this store.
//
// The schema is v1 and deliberately shaped for the phases that follow
// (gauntlet plan §2) without building them: games carries curation
// (hidden) and verify (verify_state) columns P3/P7 flip later; runs is a
// generic job table ('scan' today, 'verify'/'scrape'/'generate' from P2+);
// dat_info and scrape_coverage back DAT currency (P3) and the coverage
// tracker (P5).
//
// P4 adds the read side: ListGames paginated/filterable browsing queries
// and GetGame detail joins. Title search routes through an FTS5 index when
// this driver build provides one (probed at Open — see initSearch for the
// decision) and degrades to LIKE otherwise.
package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite" // pure-Go driver, registers as "sqlite"
)

// SchemaVersion is the current schema version, recorded in
// PRAGMA user_version. Bump and add a step in Migrate for every additive
// change; migrations are stepped and idempotent.
//
// v2 (P3): verify_results persists the last igir report's per-system
// aggregates (the zero-unmatched indicator's source), and staging carries
// the scan-time per-system incoming staging summary (files/bytes/in-flight).
//
// v3 (P3, real-igir bring-up): verify_results.extra — igir scans the
// output tree too, and output-side UNUSED rows (games-tree files the DAT
// doesn't claim) are a different signal from input-side junk; they get
// their own column + amber indicator instead of joining 'unmatched'.
//
// v4 (P4): verify_unmatched persists the offender filenames themselves
// (the P3 critic's gap — the aggregate count alone can't answer "which
// files?"), replaced per verify run, plus the runs detail JSON feeding
// SystemVerifyHistory's per-system sparkline.
//
// v5 (P5): games gains the metadata-engine columns — has_description /
// has_cover (best-effort Skyscraper cache-presence flags, flipped by the
// coverage recompute after scrape runs) and crc32 / sha1 (ingested from
// igir report rows when the report carries hash columns).
const SchemaVersion = 5

// SystemRow is one catalogue system as persisted (Extensions is a JSON
// array string — enough for P1's rendering needs).
type SystemRow struct {
	Key        string
	Collection string
	Bucket     string
	Core       string
	Emulator   string
	SkyHandle  string
	Torrent    string
	Extensions string
	SortOrder  int
}

// GameRow is one ROM file found under a system's directory, relative to
// that directory. SizeBytes is the file size; identity is (system, path).
type GameRow struct {
	RelPath   string
	SizeBytes int64
}

// DATInfo is the parsed header of <datDir>/<system>.dat plus file stats.
type DATInfo struct {
	SystemKey string
	Filename  string
	DatName   string
	Version   string
	Date      string // Logiqx header <date> (preferred) or <build>, raw text
	RomCount  int    // <game> entries in the DAT
	SizeBytes int64
	ModTime   time.Time
}

// InventoryRow is one per-system count imported from the legacy
// arcade-inventory JSON (transition aid — the webapp subsumes the
// inventory in P8).
type InventoryRow struct {
	SystemKey   string
	Count       int64
	SizeBytes   int64
	GeneratedAt string
}

// Run is one pipeline job record (kind: scan/acquire today; verify and
// dat-fetch from P3; scrape/generate later). Status: running | ok | error.
type Run struct {
	ID         int64
	Kind       string
	StartedAt  string
	FinishedAt string
	Status     string
	Detail     string
}

// VerifyResult is the last igir verify outcome for one system — the
// ingested shape of the report CSV (found/missing/unmatched/…) that the
// zero-unmatched indicator renders from. One row per system, replaced by
// each verify run; Unchecked marks the promote-without-DAT degradation
// (cartridge-verify.sh's "better partial than blocked" path — grey, not
// red).
type VerifyResult struct {
	SystemKey     string
	RunID         int64
	FinishedAt    string
	DatGames      int
	Found         int
	Missing       int
	Unmatched     int // input-side deviations (red) — see igir.Report
	Duplicate     int // output-side re-verify echoes (benign)
	Extra         int // output-side files the DAT doesn't claim (amber)
	Other         int // unknown statuses/provenance (red)
	PromotedBytes int64
	Unchecked     int // 1 = promoted as-is (no DAT)
	ReportPath    string
}

// StagingRow is the scan-time summary of one system's incoming staging
// tree (<incomingDir>/<sys>): file/byte counts plus whether aria2 control
// files were present at scan time (download in flight).
type StagingRow struct {
	SystemKey string
	Files     int64
	Bytes     int64
	InFlight  bool
}

// SystemSummary is the dashboard's card-wall row: one system joined with
// its scan aggregates.
type SystemSummary struct {
	Key          string
	Collection   string
	Bucket       string
	SortOrder    int
	Torrent      string // catalogue torrent basename ("" = no staged torrent)
	GameCount    int64
	TotalBytes   int64
	Verified     int64  // games with verify_state='verified' (P3 flips these)
	Unmatched    int64  // games with verify_state='unmatched'
	DATDate      string // "" when no DAT
	DATVersion   string
	DATRomCount  int64
	CacheEntries int64 // distinct game ids in the Skyscraper cache (heuristic)
	// Last verify run's ingested report (zero-value when none recorded) —
	// the system-level verify pill renders from this (P3), NOT from the
	// per-game aggregates: the report is the authoritative statement about
	// the staged set ("every DAT game found, nothing extra staged").
	Verify        VerifyResult
	VerifyPresent bool // a verify_results row exists
}

// Active reports whether the system has any signal to show (games, DAT, or
// cache coverage) — inactive catalogue systems collapse out of the card
// wall into the "empty systems" footer count.
func (s SystemSummary) Active() bool {
	return s.GameCount > 0 || s.DATDate != "" || s.CacheEntries > 0
}

// CoveragePct returns the Skyscraper cache coverage percentage (presence
// heuristic), or -1 when it cannot be computed (no ROMs or no cache).
func (s SystemSummary) CoveragePct() int {
	if s.GameCount <= 0 || s.CacheEntries < 0 {
		return -1
	}
	pct := int(float64(s.CacheEntries) * 100 / float64(s.GameCount))
	if pct > 100 {
		pct = 100
	}
	return pct
}

// Store wraps the SQLite handle. fts records whether this driver build
// answered the FTS5 probe at Open (search backend choice for ListGames —
// see initSearch); it selects the index plan, never the feature set.
type Store struct {
	db  *sql.DB
	fts bool
}

// Open opens (creating if needed) the database at path and applies pragmas
// + schema. The parent directory must already exist (the systemd unit's
// preStart / stateDir guarantee).
func Open(path string) (*Store, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return nil, fmt.Errorf("store: mkdir %s: %w", filepath.Dir(path), err)
	}
	dsn := "file:" + path +
		"?_pragma=journal_mode(WAL)" +
		"&_pragma=busy_timeout(10000)" +
		"&_pragma=foreign_keys(1)" +
		"&_pragma=synchronous(NORMAL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("store: open %s: %w", path, err)
	}
	// One connection: SQLite is happier with a single conn under WAL and
	// it makes the scan transaction + web reads interleave predictably.
	db.SetMaxOpenConns(1)
	s := &Store{db: db}
	if err := s.Migrate(); err != nil {
		db.Close() //nolint:errcheck // best effort during error path
		return nil, err
	}
	if err := s.initSearch(); err != nil {
		db.Close() //nolint:errcheck // best effort during error path
		return nil, err
	}
	return s, nil
}

// Migrate creates/extends the schema. Idempotent; steps forward through
// every version (a v1 database from an earlier phase migrates to v2 in
// place — the webapp has never shipped to a host, but the VM test host's
// state dir can survive across dev iterations).
func (s *Store) Migrate() error {
	var version int
	if err := s.db.QueryRow(`PRAGMA user_version`).Scan(&version); err != nil {
		return fmt.Errorf("store: read user_version: %w", err)
	}
	if version == SchemaVersion {
		return nil
	}
	if version > SchemaVersion {
		return fmt.Errorf("store: schema version %d is newer/unknown than supported %d — upgrade the webapp", version, SchemaVersion)
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck // no-op after commit
	if version < 1 {
		for _, stmt := range schemaV1 {
			if _, err := tx.Exec(stmt); err != nil {
				return fmt.Errorf("store: migrate v1: %w", err)
			}
		}
	}
	if version < 2 {
		for _, stmt := range schemaV2 {
			if _, err := tx.Exec(stmt); err != nil {
				return fmt.Errorf("store: migrate v2: %w", err)
			}
		}
	}
	if version < 3 {
		for _, stmt := range schemaV3 {
			if _, err := tx.Exec(stmt); err != nil {
				return fmt.Errorf("store: migrate v3: %w", err)
			}
		}
	}
	if version < 4 {
		for _, stmt := range schemaV4 {
			if _, err := tx.Exec(stmt); err != nil {
				return fmt.Errorf("store: migrate v4: %w", err)
			}
		}
	}
	if version < 5 {
		for _, stmt := range schemaV5 {
			if _, err := tx.Exec(stmt); err != nil {
				return fmt.Errorf("store: migrate v5: %w", err)
			}
		}
	}
	if _, err := tx.Exec(fmt.Sprintf(`PRAGMA user_version = %d`, SchemaVersion)); err != nil {
		return err
	}
	return tx.Commit()
}

var schemaV1 = []string{
	`CREATE TABLE meta (
		key   TEXT PRIMARY KEY,
		value TEXT NOT NULL
	)`,
	`CREATE TABLE systems (
		key        TEXT PRIMARY KEY,
		collection TEXT NOT NULL,
		bucket     TEXT NOT NULL CHECK (bucket IN ('cartridge','optical','modern')),
		core       TEXT NOT NULL DEFAULT '',
		emulator   TEXT NOT NULL DEFAULT '',
		sky_handle TEXT NOT NULL DEFAULT '',
		torrent    TEXT NOT NULL DEFAULT '',
		extensions TEXT NOT NULL DEFAULT '[]',
		sort_order INTEGER NOT NULL
	)`,
	`CREATE TABLE games (
		id           INTEGER PRIMARY KEY AUTOINCREMENT,
		system_key   TEXT NOT NULL REFERENCES systems(key) ON DELETE CASCADE,
		rel_path     TEXT NOT NULL,
		size_bytes   INTEGER NOT NULL,
		first_seen_at TEXT NOT NULL,
		last_seen_at  TEXT NOT NULL,
		-- Future phases (columns land now so rescans never clobber state):
		hidden        INTEGER NOT NULL DEFAULT 0,            -- P7 curation
		verify_state  TEXT NOT NULL DEFAULT 'unknown'        -- P3: unknown|verified|unmatched
	)`,
	`CREATE UNIQUE INDEX games_system_path ON games(system_key, rel_path)`,
	`CREATE INDEX games_system ON games(system_key)`,
	`CREATE TABLE dat_info (
		system_key TEXT PRIMARY KEY REFERENCES systems(key) ON DELETE CASCADE,
		filename   TEXT NOT NULL,
		dat_name   TEXT NOT NULL DEFAULT '',
		version    TEXT NOT NULL DEFAULT '',
		date       TEXT NOT NULL DEFAULT '',
		rom_count  INTEGER NOT NULL DEFAULT 0,
		size_bytes INTEGER NOT NULL DEFAULT 0,
		mod_time   TEXT NOT NULL DEFAULT ''
	)`,
	`CREATE TABLE scrape_coverage (
		system_key    TEXT PRIMARY KEY REFERENCES systems(key) ON DELETE CASCADE,
		cache_entries INTEGER NOT NULL DEFAULT 0,
		computed_at   TEXT NOT NULL
	)`,
	`CREATE TABLE inventory_counts (
		system_key   TEXT PRIMARY KEY REFERENCES systems(key) ON DELETE CASCADE,
		count        INTEGER NOT NULL,
		size_bytes   INTEGER NOT NULL,
		generated_at TEXT NOT NULL DEFAULT ''
	)`,
	`CREATE TABLE runs (
		id          INTEGER PRIMARY KEY AUTOINCREMENT,
		kind        TEXT NOT NULL,
		started_at  TEXT NOT NULL,
		finished_at TEXT NOT NULL DEFAULT '',
		status      TEXT NOT NULL,
		detail      TEXT NOT NULL DEFAULT ''
	)`,
}

var schemaV2 = []string{
	`CREATE TABLE verify_results (
		system_key     TEXT PRIMARY KEY REFERENCES systems(key) ON DELETE CASCADE,
		run_id         INTEGER NOT NULL,
		finished_at    TEXT NOT NULL,
		dat_games      INTEGER NOT NULL DEFAULT 0,
		found          INTEGER NOT NULL DEFAULT 0,
		missing        INTEGER NOT NULL DEFAULT 0,
		unmatched      INTEGER NOT NULL DEFAULT 0,
		duplicate      INTEGER NOT NULL DEFAULT 0,
		other          INTEGER NOT NULL DEFAULT 0,
		promoted_bytes INTEGER NOT NULL DEFAULT 0,
		unchecked      INTEGER NOT NULL DEFAULT 0,
		report_path    TEXT NOT NULL DEFAULT ''
	)`,
	`CREATE TABLE staging (
		system_key TEXT PRIMARY KEY REFERENCES systems(key) ON DELETE CASCADE,
		files      INTEGER NOT NULL DEFAULT 0,
		bytes      INTEGER NOT NULL DEFAULT 0,
		in_flight  INTEGER NOT NULL DEFAULT 0,
		computed_at TEXT NOT NULL
	)`,
}

// schemaV3 adds the provenance-split extra count (see SchemaVersion).
var schemaV3 = []string{
	`ALTER TABLE verify_results ADD COLUMN extra INTEGER NOT NULL DEFAULT 0`,
}

// schemaV4 persists the unmatched-file offenders (see SchemaVersion): one
// row per filename, tagged with the verify run that reported it. The
// system index serves both the read (by run+system) and the replace
// delete (by system).
var schemaV4 = []string{
	`CREATE TABLE verify_unmatched (
		run_id     INTEGER NOT NULL,
		system_key TEXT NOT NULL REFERENCES systems(key) ON DELETE CASCADE,
		filename   TEXT NOT NULL
	)`,
	`CREATE INDEX verify_unmatched_system_run ON verify_unmatched(system_key, run_id)`,
}

// schemaV5 adds the P5 metadata-engine columns to games (see
// SchemaVersion). All four are nullable/defaulted so pre-P5 rows read as
// "unscraped, unchecked" — rescans never clobber state.
var schemaV5 = []string{
	`ALTER TABLE games ADD COLUMN has_description INTEGER NOT NULL DEFAULT 0`,
	`ALTER TABLE games ADD COLUMN has_cover INTEGER NOT NULL DEFAULT 0`,
	`ALTER TABLE games ADD COLUMN crc32 TEXT`,
	`ALTER TABLE games ADD COLUMN sha1 TEXT`,
}

// Close closes the database.
func (s *Store) Close() error { return s.db.Close() }

// SchemaVersion returns the DB's recorded schema version.
func (s *Store) SchemaVersion() int {
	var v int
	if err := s.db.QueryRow(`PRAGMA user_version`).Scan(&v); err != nil {
		return -1
	}
	return v
}

// JournalMode returns the current journal_mode (diagnostic; WAL expected).
func (s *Store) JournalMode() string {
	var m string
	_ = s.db.QueryRow(`PRAGMA journal_mode`).Scan(&m)
	return m
}

// nowUTC is the persisted timestamp format (RFC3339, UTC).
func nowUTC() string { return time.Now().UTC().Format(time.RFC3339) }

// UpsertSystems replaces the systems table with rows (catalogue order is
// the sort_order). Rows absent from the new import are deleted (cascade
// clears their games/dat/coverage rows).
func (s *Store) UpsertSystems(rows []SystemRow) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck // no-op after commit
	for _, r := range rows {
		_, err := tx.Exec(`INSERT INTO systems
			(key, collection, bucket, core, emulator, sky_handle, torrent, extensions, sort_order)
			VALUES (?,?,?,?,?,?,?,?,?)
			ON CONFLICT(key) DO UPDATE SET
			  collection=excluded.collection, bucket=excluded.bucket,
			  core=excluded.core, emulator=excluded.emulator,
			  sky_handle=excluded.sky_handle, torrent=excluded.torrent,
			  extensions=excluded.extensions, sort_order=excluded.sort_order`,
			r.Key, r.Collection, r.Bucket, r.Core, r.Emulator, r.SkyHandle, r.Torrent, r.Extensions, r.SortOrder)
		if err != nil {
			return fmt.Errorf("store: upsert system %s: %w", r.Key, err)
		}
	}
	if len(rows) == 0 {
		if _, err := tx.Exec(`DELETE FROM systems`); err != nil {
			return err
		}
		return tx.Commit()
	}
	ph := "?" + strings.Repeat(",?", len(rows)-1)
	args := make([]any, len(rows))
	for i, r := range rows {
		args[i] = r.Key
	}
	if _, err := tx.Exec(`DELETE FROM systems WHERE key NOT IN (`+ph+`)`, args...); err != nil {
		return err
	}
	return tx.Commit()
}

// Systems returns all systems in catalogue order.
func (s *Store) Systems() ([]SystemRow, error) {
	rows, err := s.db.Query(`SELECT key, collection, bucket, core, emulator, sky_handle, torrent, extensions, sort_order
		FROM systems ORDER BY sort_order, key`)
	if err != nil {
		return nil, err
	}
	defer rows.Close() //nolint:errcheck // read-only
	var out []SystemRow
	for rows.Next() {
		var r SystemRow
		if err := rows.Scan(&r.Key, &r.Collection, &r.Bucket, &r.Core, &r.Emulator, &r.SkyHandle, &r.Torrent, &r.Extensions, &r.SortOrder); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// ReplaceSystemGames upserts the scanned ROM set for one system at scan
// time seen: sizes update, new files appear, vanished files are pruned.
// Curation columns (hidden, verify_state) are deliberately preserved —
// rescans never clobber later-phase state.
func (s *Store) ReplaceSystemGames(systemKey string, games []GameRow, seen time.Time) error {
	ts := seen.UTC().Format(time.RFC3339)
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck // no-op after commit
	for _, g := range games {
		_, err := tx.Exec(`INSERT INTO games (system_key, rel_path, size_bytes, first_seen_at, last_seen_at)
			VALUES (?,?,?,?,?)
			ON CONFLICT(system_key, rel_path) DO UPDATE SET
			  size_bytes=excluded.size_bytes, last_seen_at=excluded.last_seen_at`,
			systemKey, g.RelPath, g.SizeBytes, ts, ts)
		if err != nil {
			return fmt.Errorf("store: upsert game %s/%s: %w", systemKey, g.RelPath, err)
		}
	}
	if _, err := tx.Exec(`DELETE FROM games WHERE system_key=? AND last_seen_at < ?`, systemKey, ts); err != nil {
		return err
	}
	return tx.Commit()
}

// SetDATInfo upserts one system's DAT header info.
func (s *Store) SetDATInfo(info DATInfo) error {
	_, err := s.db.Exec(`INSERT INTO dat_info
		(system_key, filename, dat_name, version, date, rom_count, size_bytes, mod_time)
		VALUES (?,?,?,?,?,?,?,?)
		ON CONFLICT(system_key) DO UPDATE SET
		  filename=excluded.filename, dat_name=excluded.dat_name,
		  version=excluded.version, date=excluded.date,
		  rom_count=excluded.rom_count, size_bytes=excluded.size_bytes,
		  mod_time=excluded.mod_time`,
		info.SystemKey, info.Filename, info.DatName, info.Version, info.Date,
		info.RomCount, info.SizeBytes, info.ModTime.UTC().Format(time.RFC3339))
	return err
}

// DATInfo returns one system's DAT info, or nil when the system has no DAT
// recorded.
func (s *Store) DATInfo(systemKey string) (*DATInfo, error) {
	var d DATInfo
	var mod string
	err := s.db.QueryRow(`SELECT system_key, filename, dat_name, version, date, rom_count, size_bytes, mod_time
		FROM dat_info WHERE system_key=?`, systemKey).
		Scan(&d.SystemKey, &d.Filename, &d.DatName, &d.Version, &d.Date, &d.RomCount, &d.SizeBytes, &mod)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	d.ModTime, _ = time.Parse(time.RFC3339, mod)
	return &d, nil
}

// SetScrapeCoverage records the Skyscraper cache game count for a system.
func (s *Store) SetScrapeCoverage(systemKey string, cacheEntries int64) error {
	_, err := s.db.Exec(`INSERT INTO scrape_coverage (system_key, cache_entries, computed_at)
		VALUES (?,?,?)
		ON CONFLICT(system_key) DO UPDATE SET
		  cache_entries=excluded.cache_entries, computed_at=excluded.computed_at`,
		systemKey, cacheEntries, nowUTC())
	return err
}

// ---- P5: metadata-engine columns ------------------------------------------

// GameScrapeFlag is one game's best-effort Skyscraper cache-presence
// flags (the coverage tracker's per-game drill-down data).
type GameScrapeFlag struct {
	RelPath     string
	Description bool
	Cover       bool
}

// SetSystemScrapeFlags applies one system's per-game has_description /
// has_cover flips in a single transaction with full-replace semantics
// (mirroring SetSystemVerifyStates): every row of the system is zeroed
// first, then the listed positives are set. Games absent from flags end
// up unflagged — a recompute pass always describes the WHOLE system's
// cache state, so stale flags cannot survive a cache wipe.
func (s *Store) SetSystemScrapeFlags(systemKey string, flags []GameScrapeFlag) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck // no-op after commit
	if _, err := tx.Exec(`UPDATE games SET has_description=0, has_cover=0 WHERE system_key=?`, systemKey); err != nil {
		return err
	}
	for _, f := range flags {
		if _, err := tx.Exec(`UPDATE games SET has_description=?, has_cover=? WHERE system_key=? AND rel_path=?`,
			boolInt(f.Description), boolInt(f.Cover), systemKey, f.RelPath); err != nil {
			return fmt.Errorf("store: scrape flag %s/%s: %w", systemKey, f.RelPath, err)
		}
	}
	return tx.Commit()
}

// GameChecksum is one game's checksums as ingested from a checksum-bearing
// igir report's FOUND rows.
type GameChecksum struct {
	RelPath string
	CRC32   string
	SHA1    string
}

// SetGameChecksums persists per-game crc32/sha1 in one transaction.
// SELECTIVE update: an empty field leaves the stored value untouched
// (CASE WHEN ? != ”), because reports without hash columns must not
// erase checksums a previous richer report recorded, and a partial row
// (CRC only) must not clear a known SHA1. Callers wanting a true clear
// can pass a literal sentinel — none exists today by design.
func (s *Store) SetGameChecksums(systemKey string, cks []GameChecksum) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck // no-op after commit
	for _, c := range cks {
		if _, err := tx.Exec(`UPDATE games SET
			crc32 = CASE WHEN ?1 != '' THEN ?1 ELSE crc32 END,
			sha1  = CASE WHEN ?2 != '' THEN ?2 ELSE sha1 END
			WHERE system_key=?3 AND rel_path=?4`, c.CRC32, c.SHA1, systemKey, c.RelPath); err != nil {
			return fmt.Errorf("store: game checksum %s/%s: %w", systemKey, c.RelPath, err)
		}
	}
	return tx.Commit()
}

// ReplaceInventory swaps the imported legacy inventory rows in one go
// (nil = absent inventory file → table cleared).
func (s *Store) ReplaceInventory(rows []InventoryRow) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck // no-op after commit
	if _, err := tx.Exec(`DELETE FROM inventory_counts`); err != nil {
		return err
	}
	for _, r := range rows {
		if _, err := tx.Exec(`INSERT INTO inventory_counts (system_key, count, size_bytes, generated_at)
			VALUES (?,?,?,?)`,
			r.SystemKey, r.Count, r.SizeBytes, r.GeneratedAt); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// InventoryRows returns the imported legacy inventory rows in catalogue
// order (empty when the last scan found no inventory file).
func (s *Store) InventoryRows() ([]InventoryRow, error) {
	rows, err := s.db.Query(`SELECT i.system_key, i.count, i.size_bytes, i.generated_at
		FROM inventory_counts i JOIN systems s ON s.key = i.system_key
		ORDER BY s.sort_order`)
	if err != nil {
		return nil, err
	}
	defer rows.Close() //nolint:errcheck // read-only
	var out []InventoryRow
	for rows.Next() {
		var r InventoryRow
		if err := rows.Scan(&r.SystemKey, &r.Count, &r.SizeBytes, &r.GeneratedAt); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// StartRun records a running job and returns its id.
func (s *Store) StartRun(kind string) (int64, error) {
	res, err := s.db.Exec(`INSERT INTO runs (kind, started_at, status) VALUES (?,?, 'running')`,
		kind, nowUTC())
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

// FinishRun closes a job with status (ok|error) and a detail payload
// (JSON summary or error text).
func (s *Store) FinishRun(id int64, status, detail string) error {
	_, err := s.db.Exec(`UPDATE runs SET finished_at=?, status=?, detail=? WHERE id=?`,
		nowUTC(), status, detail, id)
	return err
}

// LastRun returns the most recent run, or nil when none exist.
func (s *Store) LastRun() (*Run, error) {
	runs, err := s.RecentRuns(1)
	if err != nil {
		return nil, err
	}
	if len(runs) == 0 {
		return nil, nil
	}
	return &runs[0], nil
}

// RecentRuns returns up to n runs, newest first.
func (s *Store) RecentRuns(n int) ([]Run, error) {
	rows, err := s.db.Query(`SELECT id, kind, started_at, finished_at, status, detail
		FROM runs ORDER BY id DESC LIMIT ?`, n)
	if err != nil {
		return nil, err
	}
	defer rows.Close() //nolint:errcheck // read-only
	var out []Run
	for rows.Next() {
		var r Run
		if err := rows.Scan(&r.ID, &r.Kind, &r.StartedAt, &r.FinishedAt, &r.Status, &r.Detail); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// SystemSummary returns every system with its scan aggregates, in
// catalogue order — the dashboard card wall query. The verify_results
// join carries the last igir report's aggregates per system (P3).
func (s *Store) SystemSummary() ([]SystemSummary, error) {
	rows, err := s.db.Query(`
		SELECT s.key, s.collection, s.bucket, s.sort_order, s.torrent,
		       COALESCE(g.cnt, 0), COALESCE(g.bytes, 0),
		       COALESCE(g.verified, 0), COALESCE(g.unmatched, 0),
		       COALESCE(d.date, ''), COALESCE(d.version, ''), COALESCE(d.rom_count, 0),
		       COALESCE(c.cache_entries, 0),
		       COALESCE(v.run_id, 0), COALESCE(v.finished_at, ''),
		       COALESCE(v.dat_games, 0), COALESCE(v.found, 0), COALESCE(v.missing, 0),
		       COALESCE(v.unmatched, 0), COALESCE(v.duplicate, 0), COALESCE(v.other, 0),
		       COALESCE(v.extra, 0),
		       COALESCE(v.promoted_bytes, 0), COALESCE(v.unchecked, 0), COALESCE(v.report_path, ''),
		       CASE WHEN v.system_key IS NULL THEN 0 ELSE 1 END
		FROM systems s
		LEFT JOIN (SELECT system_key, COUNT(*) cnt, SUM(size_bytes) bytes,
		                  SUM(CASE WHEN verify_state='verified' THEN 1 ELSE 0 END) verified,
		                  SUM(CASE WHEN verify_state='unmatched' THEN 1 ELSE 0 END) unmatched
		           FROM games GROUP BY system_key) g ON g.system_key = s.key
		LEFT JOIN dat_info d ON d.system_key = s.key
		LEFT JOIN scrape_coverage c ON c.system_key = s.key
		LEFT JOIN verify_results v ON v.system_key = s.key
		ORDER BY s.sort_order, s.key`)
	if err != nil {
		return nil, err
	}
	defer rows.Close() //nolint:errcheck // read-only
	var out []SystemSummary
	for rows.Next() {
		var r SystemSummary
		if err := rows.Scan(&r.Key, &r.Collection, &r.Bucket, &r.SortOrder, &r.Torrent,
			&r.GameCount, &r.TotalBytes, &r.Verified, &r.Unmatched,
			&r.DATDate, &r.DATVersion, &r.DATRomCount,
			&r.CacheEntries,
			&r.Verify.RunID, &r.Verify.FinishedAt,
			&r.Verify.DatGames, &r.Verify.Found, &r.Verify.Missing,
			&r.Verify.Unmatched, &r.Verify.Duplicate, &r.Verify.Other,
			&r.Verify.Extra,
			&r.Verify.PromotedBytes, &r.Verify.Unchecked, &r.Verify.ReportPath,
			&r.VerifyPresent); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// RecordVerifyResult upserts one system's last-verify aggregates (each
// verify run replaces the previous row — the pill always shows the latest
// report).
func (s *Store) RecordVerifyResult(r VerifyResult) error {
	_, err := s.db.Exec(`INSERT INTO verify_results
		(system_key, run_id, finished_at, dat_games, found, missing, unmatched, duplicate, other, extra, promoted_bytes, unchecked, report_path)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(system_key) DO UPDATE SET
		  run_id=excluded.run_id, finished_at=excluded.finished_at,
		  dat_games=excluded.dat_games, found=excluded.found, missing=excluded.missing,
		  unmatched=excluded.unmatched, duplicate=excluded.duplicate, other=excluded.other,
		  extra=excluded.extra, promoted_bytes=excluded.promoted_bytes,
		  unchecked=excluded.unchecked, report_path=excluded.report_path`,
		r.SystemKey, r.RunID, r.FinishedAt, r.DatGames, r.Found, r.Missing,
		r.Unmatched, r.Duplicate, r.Other, r.Extra, r.PromotedBytes, r.Unchecked, r.ReportPath)
	return err
}

// SetSystemVerifyStates applies one verify run's per-game state flips for
// a system in a single transaction: rel paths claimed by the report's
// FOUND rows become 'verified', every OTHER row of the system becomes
// 'unmatched' — the DAT is authoritative, so a games-tree file the DAT
// does not cover is by definition not verified (cartridge-verify.sh's
// design note: unmatched files are deliberately excluded from a 1G1R
// collection; here they stay visible instead of vanishing).
func (s *Store) SetSystemVerifyStates(systemKey string, verifiedRels []string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck // no-op after commit
	if _, err := tx.Exec(`UPDATE games SET verify_state='unmatched' WHERE system_key=?`, systemKey); err != nil {
		return err
	}
	for _, rel := range verifiedRels {
		if _, err := tx.Exec(`UPDATE games SET verify_state='verified' WHERE system_key=? AND rel_path=?`,
			systemKey, rel); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// ---- P4: unmatched-file persistence + verify history ----------------------

// RecordVerifyUnmatched persists one verify run's unmatched-file list for
// a system in a single transaction: the system's previous rows are
// deleted (replace semantics — the table always describes the latest
// verify) and the new filenames inserted under the run id that produced
// them. The caller reads them back with VerifyUnmatched(runID, systemKey)
// — the pair is the identity, so an older run's list reads as gone after
// a newer one replaced it.
func (s *Store) RecordVerifyUnmatched(systemKey string, runID int64, files []string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck // no-op after commit
	if _, err := tx.Exec(`DELETE FROM verify_unmatched WHERE system_key=?`, systemKey); err != nil {
		return fmt.Errorf("store: clear unmatched %s: %w", systemKey, err)
	}
	for _, f := range files {
		if _, err := tx.Exec(`INSERT INTO verify_unmatched (run_id, system_key, filename) VALUES (?,?,?)`,
			runID, systemKey, f); err != nil {
			return fmt.Errorf("store: record unmatched %s/%s: %w", systemKey, f, err)
		}
	}
	return tx.Commit()
}

// VerifyUnmatched returns the persisted unmatched filenames for one
// system's verify run, filename-ordered; nil when nothing is recorded for
// that pair.
func (s *Store) VerifyUnmatched(runID int64, systemKey string) ([]string, error) {
	rows, err := s.db.Query(`SELECT filename FROM verify_unmatched
		WHERE run_id=? AND system_key=? ORDER BY filename`, runID, systemKey)
	if err != nil {
		return nil, err
	}
	defer rows.Close() //nolint:errcheck // read-only
	var out []string
	for rows.Next() {
		var f string
		if err := rows.Scan(&f); err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

// VerifyRunPoint is one historical verify run's outcome for a system — a
// history sparkline data point.
type VerifyRunPoint struct {
	FinishedAt string
	Found      int
	Unmatched  int
	Extra      int
}

// verifyHistoryScanBound caps how many runs SystemVerifyHistory walks no
// matter what n asks for — the sparkline never needs more and the scan
// must stay cheap even on a long-lived database.
const verifyHistoryScanBound = 100

// verifyRunDetail mirrors the JSON FinishRun detail payload internal/igir
// writes (only the fields the history needs).
type verifyRunDetail struct {
	Systems []struct {
		Sys       string `json:"Sys"`
		Found     int    `json:"Found"`
		Unmatched int    `json:"Unmatched"`
		Extra     int    `json:"Extra"`
	} `json:"Systems"`
}

// SystemVerifyHistory returns up to n verify-run outcomes for one system,
// newest first. It scans runs WHERE kind='verify' newest-first (bounded by
// verifyHistoryScanBound), parsing each run's detail JSON for that
// system's outcome; runs without a detail entry for the system (other
// systems only, or non-JSON error text) contribute nothing. n<=0 yields
// nil.
func (s *Store) SystemVerifyHistory(systemKey string, n int) ([]VerifyRunPoint, error) {
	if n <= 0 {
		return nil, nil
	}
	rows, err := s.db.Query(`SELECT finished_at, detail FROM runs
		WHERE kind='verify' ORDER BY id DESC LIMIT ?`, verifyHistoryScanBound)
	if err != nil {
		return nil, err
	}
	defer rows.Close() //nolint:errcheck // read-only
	var out []VerifyRunPoint
	for rows.Next() {
		var finished, detail string
		if err := rows.Scan(&finished, &detail); err != nil {
			return nil, err
		}
		var d verifyRunDetail
		if err := json.Unmarshal([]byte(detail), &d); err != nil {
			continue // error-text detail: nothing plottable in this run
		}
		for _, sys := range d.Systems {
			if sys.Sys != systemKey {
				continue
			}
			out = append(out, VerifyRunPoint{FinishedAt: finished, Found: sys.Found, Unmatched: sys.Unmatched, Extra: sys.Extra})
			break
		}
		if len(out) >= n {
			break
		}
	}
	return out, rows.Err()
}

// ReplaceStaging upserts the scan-time incoming staging summary rows.
// Rows for systems absent from the batch are cleared (a scan that found
// no incoming dir reports zeros, keeping the table in step with disk).
func (s *Store) ReplaceStaging(rows []StagingRow) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck // no-op after commit
	if _, err := tx.Exec(`DELETE FROM staging`); err != nil {
		return err
	}
	for _, r := range rows {
		if _, err := tx.Exec(`INSERT INTO staging (system_key, files, bytes, in_flight, computed_at)
			VALUES (?,?,?,?,?)`,
			r.SystemKey, r.Files, r.Bytes, boolInt(r.InFlight), nowUTC()); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// StagingRows returns the per-system staging summaries in catalogue order.
func (s *Store) StagingRows() ([]StagingRow, error) {
	rows, err := s.db.Query(`SELECT t.system_key, t.files, t.bytes, t.in_flight
		FROM staging t JOIN systems s ON s.key = t.system_key
		ORDER BY s.sort_order`)
	if err != nil {
		return nil, err
	}
	defer rows.Close() //nolint:errcheck // read-only
	var out []StagingRow
	for rows.Next() {
		var r StagingRow
		var inflight int
		if err := rows.Scan(&r.SystemKey, &r.Files, &r.Bytes, &inflight); err != nil {
			return nil, err
		}
		r.InFlight = inflight != 0
		out = append(out, r)
	}
	return out, rows.Err()
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// GameVerifyState returns one game row's verify_state ("unknown" when
// the row does not exist).
func (s *Store) GameVerifyState(systemKey, relPath string) string {
	var v string
	_ = s.db.QueryRow(`SELECT verify_state FROM games WHERE system_key=? AND rel_path=?`,
		systemKey, relPath).Scan(&v)
	return v
}

// SetMeta upserts a meta key (scan telemetry the status strip reads back).
func (s *Store) SetMeta(key, value string) error {
	_, err := s.db.Exec(`INSERT INTO meta (key, value) VALUES (?,?)
		ON CONFLICT(key) DO UPDATE SET value=excluded.value`, key, value)
	return err
}

// GetMeta returns a meta value, or "" when unset.
func (s *Store) GetMeta(key string) string {
	var v string
	_ = s.db.QueryRow(`SELECT value FROM meta WHERE key=?`, key).Scan(&v)
	return v
}

// ---- P4: library browsing (ListGames / GetGame) ---------------------------

// Search backend decision (gauntlet plan §2 P4): driver builds vary in
// which SQLite extensions they compile in, so Open probes once by creating
// a throwaway FTS5 table in the connection's scratch in-memory temp schema.
// When the probe answers, q searches run through an external-content
// games_fts index kept current by triggers on games (rebuild-once
// bookkeeping via meta 'fts_ready'); when it does not, the same filter
// degrades to LIKE '%q%' + ORDER BY over the base table — identical
// feature surface, no extra schema, just a slower scan. The index is
// derived state: deliberately not versioned in user_version, droppable and
// rebuildable at will, and self-healing if a database written by an
// FTS5-capable binary is later opened by one without it.
//
// Semantics note: FTS5 matches case-folded TOKEN prefixes ("zel" hits
// "Zelda", mid-word "elda" does not); LIKE matches case-folded SUBSTRINGS
// anywhere. Callers get word-prefix search either way; only the fallback
// honors arbitrary mid-word substrings.
const (
	// SortTitle orders by rel_path case-insensitively — the filename is
	// the title source until Skyscraper metadata lands (P5).
	SortTitle = "title"
	// SortSize orders biggest first.
	SortSize = "size"
	// SortRecent orders by last_seen_at, newest first.
	SortRecent = "recent"
)

// GameSummary is one row of ListGames output. RelPath doubles as the
// display/search title until per-game metadata arrives (P5).
type GameSummary struct {
	ID          int64
	SystemKey   string
	RelPath     string
	SizeBytes   int64
	FirstSeenAt string
	LastSeenAt  string
	Hidden      bool
	VerifyState string
}

// GameDetail is GetGame's shape: one game joined with its owning system.
// The P5 fields (HasDescription/HasCover, CRC32/SHA1) carry the metadata
// engine's best-effort cache flags and the igir-ingested checksums —
// zero-value ("unscraped") until a scrape run / checksum-bearing report
// fills them.
type GameDetail struct {
	GameSummary
	System         SystemRow
	HasDescription bool
	HasCover       bool
	CRC32          string
	SHA1           string
}

// GameListOpts filters/sorts/paginates ListGames. Empty strings mean "no
// filter"; Hidden=nil means "both". Sort is "" | SortTitle | SortSize |
// SortRecent (anything else is an error). Limit<=0 returns everything;
// Offset only applies together with a positive Limit.
type GameListOpts struct {
	SystemKey   string
	Q           string
	VerifyState string
	Hidden      *bool
	Sort        string
	Limit       int
	Offset      int
}

// GamePage is one page of results plus the unpaginated total matching the
// same filters (the pager renders from Total).
type GamePage struct {
	Games []GameSummary
	Total int64
}

// ftsDDL keeps the external-content FTS5 mirror of games.rel_path in step.
// The UPDATE trigger only fires for rel_path changes — rescan size
// updates, verify_state flips and hidden toggles skip reindexing entirely.
var ftsDDL = []string{
	`CREATE VIRTUAL TABLE IF NOT EXISTS games_fts USING fts5(
		rel_path,
		content='games',
		content_rowid='id'
	)`,
	`CREATE TRIGGER IF NOT EXISTS games_fts_ai AFTER INSERT ON games BEGIN
		INSERT INTO games_fts(rowid, rel_path) VALUES (new.id, new.rel_path);
	END`,
	`CREATE TRIGGER IF NOT EXISTS games_fts_au AFTER UPDATE OF rel_path ON games BEGIN
		INSERT INTO games_fts(games_fts, rowid, rel_path) VALUES('delete', old.id, old.rel_path);
		INSERT INTO games_fts(rowid, rel_path) VALUES (new.id, new.rel_path);
	END`,
	`CREATE TRIGGER IF NOT EXISTS games_fts_ad AFTER DELETE ON games BEGIN
		INSERT INTO games_fts(games_fts, rowid, rel_path) VALUES('delete', old.id, old.rel_path);
	END`,
}

// fts5Supported answers whether THIS build of the linked driver registers
// FTS5, via the cheapest possible virtual DDL against the temp schema
// (private to the connection, so probing leaves no trace).
func fts5Supported(db *sql.DB) bool {
	if _, err := db.Exec(`CREATE VIRTUAL TABLE temp.store_fts5_probe USING fts5(x)`); err != nil {
		return false
	}
	_, _ = db.Exec(`DROP TABLE IF EXISTS temp.store_fts5_probe`)
	return true
}

// initSearch picks the ListGames search backend (see the section comment)
// and on the FTS5 path creates the shadow index + sync triggers and
// backfills once. A database previously written by an FTS5-capable binary
// but opened by one without it self-heals here: leftover triggers would
// otherwise fail every rescan write.
func (s *Store) initSearch() error {
	s.fts = fts5Supported(s.db)
	if !s.fts {
		for _, stmt := range []string{
			`DROP TRIGGER IF EXISTS games_fts_ai`,
			`DROP TRIGGER IF EXISTS games_fts_au`,
			`DROP TRIGGER IF EXISTS games_fts_ad`,
			`DROP TABLE IF EXISTS games_fts`,
		} {
			if _, err := s.db.Exec(stmt); err != nil {
				return fmt.Errorf("store: drop stale fts objects: %w", err)
			}
		}
		return nil
	}
	for _, stmt := range ftsDDL {
		if _, err := s.db.Exec(stmt); err != nil {
			return fmt.Errorf("store: fts ddl: %w", err)
		}
	}
	var ready string
	_ = s.db.QueryRow(`SELECT value FROM meta WHERE key='fts_ready'`).Scan(&ready)
	if ready != "1" {
		// The external-content rebuild re-derives the whole index from
		// games — idempotent, so also correct after a crash between DDL
		// and flag.
		if _, err := s.db.Exec(`INSERT INTO games_fts(games_fts) VALUES('rebuild')`); err != nil {
			return fmt.Errorf("store: fts rebuild: %w", err)
		}
		if err := s.SetMeta("fts_ready", "1"); err != nil {
			return fmt.Errorf("store: mark fts ready: %w", err)
		}
	}
	return nil
}

// FTSSearchEnabled reports which search backend ListGames routes q through
// (true = FTS5 index, false = LIKE fallback) — for diagnostics and tests.
func (s *Store) FTSSearchEnabled() bool { return s.fts }

// ListGames runs one paginated library-browsing query (P4): optional title
// substring q (case-insensitive), system, verify state and hidden flag;
// sorted and paged, with the unpaginated match total for the pager.
func (s *Store) ListGames(opts GameListOpts) (GamePage, error) {
	order, err := gameOrderBy(opts.Sort)
	if err != nil {
		return GamePage{}, err
	}
	where := []string{"1=1"}
	args := []any{}
	if opts.SystemKey != "" {
		where = append(where, `g.system_key = ?`)
		args = append(args, opts.SystemKey)
	}
	if opts.VerifyState != "" {
		where = append(where, `g.verify_state = ?`)
		args = append(args, opts.VerifyState)
	}
	if opts.Hidden != nil {
		where = append(where, `g.hidden = ?`)
		args = append(args, boolInt(*opts.Hidden))
	}
	switch q := strings.TrimSpace(opts.Q); {
	case q == "":
	case s.fts && ftsMatchQuery(q) == "":
		// Only quotes/punctuation: nothing tokenizable to match (the LIKE
		// branch would scan for the raw bytes and find none either).
		where = append(where, `1=0`)
	case s.fts:
		where = append(where, `g.id IN (SELECT rowid FROM games_fts WHERE games_fts MATCH ?)`)
		args = append(args, ftsMatchQuery(q))
	default:
		where = append(where, `lower(g.rel_path) LIKE ? ESCAPE '\'`)
		args = append(args, "%"+likeEscape(strings.ToLower(q))+"%")
	}
	cond := strings.Join(where, " AND ")

	page := GamePage{}
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM games g WHERE `+cond, args...).Scan(&page.Total); err != nil {
		return GamePage{}, fmt.Errorf("store: list games count: %w", err)
	}

	query := `SELECT g.id, g.system_key, g.rel_path, g.size_bytes,
			g.first_seen_at, g.last_seen_at, g.hidden, g.verify_state
		FROM games g WHERE ` + cond + ` ORDER BY ` + order
	qargs := args
	if opts.Limit > 0 {
		query += ` LIMIT ?`
		qargs = append(qargs, opts.Limit)
		if opts.Offset > 0 {
			query += ` OFFSET ?`
			qargs = append(qargs, opts.Offset)
		}
	}
	rows, err := s.db.Query(query, qargs...)
	if err != nil {
		return GamePage{}, fmt.Errorf("store: list games: %w", err)
	}
	defer rows.Close() //nolint:errcheck // read-only
	for rows.Next() {
		var g GameSummary
		var hidden int
		if err := rows.Scan(&g.ID, &g.SystemKey, &g.RelPath, &g.SizeBytes,
			&g.FirstSeenAt, &g.LastSeenAt, &hidden, &g.VerifyState); err != nil {
			return GamePage{}, err
		}
		g.Hidden = hidden != 0
		page.Games = append(page.Games, g)
	}
	return page, rows.Err()
}

// gameOrderBy maps a GameListOpts.Sort to a deterministic ORDER BY (stable
// id tie-break in matching direction, so pagination never repeats or
// drops boundary rows).
func gameOrderBy(sort string) (string, error) {
	switch sort {
	case "", SortTitle:
		return `g.rel_path COLLATE NOCASE ASC, g.id ASC`, nil
	case SortSize:
		return `g.size_bytes DESC, g.id ASC`, nil
	case SortRecent:
		return `g.last_seen_at DESC, g.id DESC`, nil
	default:
		return "", fmt.Errorf("store: unknown game sort %q (want title|size|recent)", sort)
	}
}

// GetGame returns one game joined with its system (the detail-page query),
// or nil when the (system, id) pair has no row — the system key is part of
// the identity, so a valid id under the wrong system reads as absent.
func (s *Store) GetGame(systemKey string, id int64) (*GameDetail, error) {
	var d GameDetail
	var hidden int
	var desc, cover int
	err := s.db.QueryRow(`
		SELECT g.id, g.system_key, g.rel_path, g.size_bytes, g.first_seen_at, g.last_seen_at,
		       g.hidden, g.verify_state,
		       COALESCE(g.has_description, 0), COALESCE(g.has_cover, 0),
		       COALESCE(g.crc32, ''), COALESCE(g.sha1, ''),
		       s.key, s.collection, s.bucket, s.core, s.emulator, s.sky_handle, s.torrent, s.extensions, s.sort_order
		FROM games g JOIN systems s ON s.key = g.system_key
		WHERE g.system_key = ? AND g.id = ?`, systemKey, id).
		Scan(&d.ID, &d.SystemKey, &d.RelPath, &d.SizeBytes, &d.FirstSeenAt, &d.LastSeenAt,
			&hidden, &d.VerifyState,
			&desc, &cover, &d.CRC32, &d.SHA1,
			&d.System.Key, &d.System.Collection, &d.System.Bucket, &d.System.Core,
			&d.System.Emulator, &d.System.SkyHandle, &d.System.Torrent,
			&d.System.Extensions, &d.System.SortOrder)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("store: get game %s/%d: %w", systemKey, id, err)
	}
	d.Hidden = hidden != 0
	d.HasDescription = desc != 0
	d.HasCover = cover != 0
	return &d, nil
}

var likeEscaper = strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)

// likeEscape neutralizes LIKE metacharacters in user input (paired with
// ESCAPE '\' in the fallback predicate).
func likeEscape(q string) string { return likeEscaper.Replace(q) }

// ftsMatchQuery turns free text into a safe FTS5 MATCH expression: each
// whitespace-separated term becomes a quoted prefix term ("term"*), so user
// input can neither break MATCH syntax nor inject operators. Terms made
// entirely of quotes/punctuation yield "" (caller decides zero-match).
func ftsMatchQuery(q string) string {
	parts := make([]string, 0, 8)
	for _, tok := range strings.Fields(q) {
		tok = strings.ReplaceAll(tok, `"`, "")
		if tok == "" {
			continue
		}
		parts = append(parts, `"`+tok+`"*`)
	}
	return strings.Join(parts, " ")
}
