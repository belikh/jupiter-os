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
package store

import (
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite" // pure-Go driver, registers as "sqlite"
)

// SchemaVersion is the current schema version, recorded in meta. Bump and
// migrate forward in Migrate when a later phase changes the schema.
//
// v2 (P3): verify_results persists the last igir report's per-system
// aggregates (the zero-unmatched indicator's source), and staging carries
// the scan-time per-system incoming staging summary (files/bytes/in-flight).
const SchemaVersion = 2

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
	Unmatched     int
	Duplicate     int
	Other         int
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

// Store wraps the SQLite handle.
type Store struct {
	db *sql.DB
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
		(system_key, run_id, finished_at, dat_games, found, missing, unmatched, duplicate, other, promoted_bytes, unchecked, report_path)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT(system_key) DO UPDATE SET
		  run_id=excluded.run_id, finished_at=excluded.finished_at,
		  dat_games=excluded.dat_games, found=excluded.found, missing=excluded.missing,
		  unmatched=excluded.unmatched, duplicate=excluded.duplicate, other=excluded.other,
		  promoted_bytes=excluded.promoted_bytes, unchecked=excluded.unchecked,
		  report_path=excluded.report_path`,
		r.SystemKey, r.RunID, r.FinishedAt, r.DatGames, r.Found, r.Missing,
		r.Unmatched, r.Duplicate, r.Other, r.PromotedBytes, r.Unchecked, r.ReportPath)
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
