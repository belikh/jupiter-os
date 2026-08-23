package store

import (
	"database/sql"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"

	_ "modernc.org/sqlite" // raw handle for the v1-migration test
)

func openTemp(t *testing.T) *Store {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestOpenIdempotentAndWAL(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "test.db")

	s1, err := Open(p)
	if err != nil {
		t.Fatalf("open 1: %v", err)
	}
	// Migrate runs on Open; opening again must be a no-op, not an error.
	if err := s1.Migrate(); err != nil {
		t.Fatalf("re-Migrate: %v", err)
	}
	if got := s1.SchemaVersion(); got != SchemaVersion {
		t.Errorf("SchemaVersion = %d, want %d", got, SchemaVersion)
	}
	if err := s1.Close(); err != nil {
		t.Fatalf("close 1: %v", err)
	}

	s2, err := Open(p)
	if err != nil {
		t.Fatalf("open 2 (existing file): %v", err)
	}
	defer s2.Close() //nolint:errcheck // test
	if got := s2.SchemaVersion(); got != SchemaVersion {
		t.Errorf("SchemaVersion after reopen = %d, want %d", got, SchemaVersion)
	}
	if mode := s2.JournalMode(); mode != "wal" {
		t.Errorf("journal_mode = %q, want wal (ADR-0002 D3)", mode)
	}
}

func TestUpsertSystemsPreservesOrderAndReplacesRows(t *testing.T) {
	s := openTemp(t)
	first := []SystemRow{
		{Key: "nes", Collection: "NES", Bucket: "cartridge", SortOrder: 1, Extensions: `["nes"]`},
		{Key: "snes", Collection: "SNES", Bucket: "cartridge", SortOrder: 2, Extensions: `["sfc","smc"]`},
	}
	if err := s.UpsertSystems(first); err != nil {
		t.Fatalf("UpsertSystems: %v", err)
	}
	// Second import: one edited row, one new row, one dropped row.
	if err := s.UpsertSystems([]SystemRow{
		{Key: "nes", Collection: "Nintendo Entertainment System", Bucket: "cartridge", SortOrder: 1, Extensions: `["nes"]`},
		{Key: "gb", Collection: "Game Boy", Bucket: "cartridge", SortOrder: 3, Extensions: `["gb"]`},
	}); err != nil {
		t.Fatalf("UpsertSystems 2: %v", err)
	}
	got, err := s.Systems()
	if err != nil {
		t.Fatalf("Systems: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("len(Systems) = %d, want 2 (snes dropped, nes+gb kept)", len(got))
	}
	if got[0].Key != "nes" || got[0].Collection != "Nintendo Entertainment System" {
		t.Errorf("systems[0] = %+v, want edited nes", got[0])
	}
	if got[1].Key != "gb" {
		t.Errorf("systems[1].Key = %q, want gb", got[1].Key)
	}
}

func TestReplaceSystemGamesUpsertPreservesCurationColumns(t *testing.T) {
	s := openTemp(t)
	if err := s.UpsertSystems([]SystemRow{{Key: "nes", Collection: "NES", Bucket: "cartridge", SortOrder: 1, Extensions: `["nes"]`}}); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	games := []GameRow{
		{RelPath: "A (USA).nes", SizeBytes: 100},
		{RelPath: "B (USA).nes", SizeBytes: 200},
	}
	if err := s.ReplaceSystemGames("nes", games, now); err != nil {
		t.Fatalf("ReplaceSystemGames: %v", err)
	}

	// Simulate P3/P7 state the rescan must NOT clobber.
	if _, err := s.db.Exec(`UPDATE games SET verify_state='verified', hidden=1 WHERE rel_path='A (USA).nes'`); err != nil {
		t.Fatal(err)
	}

	// Rescan sees one game gone, one resized, one new.
	if err := s.ReplaceSystemGames("nes", []GameRow{
		{RelPath: "A (USA).nes", SizeBytes: 111},
		{RelPath: "C (JP).nes", SizeBytes: 300},
	}, now.Add(time.Minute)); err != nil {
		t.Fatalf("ReplaceSystemGames 2: %v", err)
	}

	var count int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM games WHERE system_key='nes'`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 2 {
		t.Fatalf("game count = %d, want 2 (B pruned)", count)
	}
	var vs string
	var hidden int
	if err := s.db.QueryRow(`SELECT verify_state, hidden FROM games WHERE rel_path='A (USA).nes'`).Scan(&vs, &hidden); err != nil {
		t.Fatal(err)
	}
	if vs != "verified" || hidden != 1 {
		t.Errorf("rescan clobbered future-phase state: verify_state=%q hidden=%d", vs, hidden)
	}
	var size int64
	if err := s.db.QueryRow(`SELECT size_bytes FROM games WHERE rel_path='A (USA).nes'`).Scan(&size); err != nil {
		t.Fatal(err)
	}
	if size != 111 {
		t.Errorf("size after rescan = %d, want 111", size)
	}
}

// TestReplaceSystemGamesPrunesAcrossSubSecondBoundary pins ADV-P6-01:
// two replaces inside the SAME wall-clock second must order
// deterministically. On the old second-truncated stamps both writes
// shared one string, so a subset replace milliseconds after a full one
// could never prune (and, crossing the boundary the other way, deleted
// rows upserted moments earlier — the generate-test ENOENT flake).
func TestReplaceSystemGamesPrunesAcrossSubSecondBoundary(t *testing.T) {
	s := openTemp(t)
	if err := s.UpsertSystems([]SystemRow{{Key: "nes", Collection: "NES", Bucket: "cartridge", SortOrder: 1, Extensions: `["nes"]`}}); err != nil {
		t.Fatal(err)
	}
	// Strictly INSIDE a second: every write below shares its truncation.
	base := time.Now().UTC().Truncate(time.Second).Add(100 * time.Millisecond)
	if err := s.ReplaceSystemGames("nes", []GameRow{
		{RelPath: "A (USA).nes", SizeBytes: 1},
		{RelPath: "B (USA).nes", SizeBytes: 2},
	}, base); err != nil {
		t.Fatal(err)
	}
	// 250ms later, still the same second, A has vanished from the scan.
	if err := s.ReplaceSystemGames("nes", []GameRow{
		{RelPath: "B (USA).nes", SizeBytes: 2},
	}, base.Add(250*time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	var got []string
	rows, err := s.db.Query(`SELECT rel_path FROM games WHERE system_key='nes' ORDER BY rel_path`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close() //nolint:errcheck // read-only
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			t.Fatal(err)
		}
		got = append(got, p)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0] != "B (USA).nes" {
		t.Fatalf("rows after sub-second subset replace = %v, want [B (USA).nes] (A pruned)", got)
	}

	// The stamps themselves carry sub-second precision (the fixed-width
	// fraction is what makes the string prune correct).
	var stamp string
	if err := s.db.QueryRow(`SELECT last_seen_at FROM games WHERE rel_path='B (USA).nes'`).Scan(&stamp); err != nil {
		t.Fatal(err)
	}
	parsed, err := time.Parse(time.RFC3339Nano, stamp)
	if err != nil {
		t.Fatalf("last_seen_at %q unparsable: %v", stamp, err)
	}
	if frac := parsed.Nanosecond(); frac != 350_000_000 {
		t.Fatalf("last_seen_at fraction = %d ns, want 350000000 (100ms base + 250ms)", frac)
	}
}

// TestReplaceSystemGamesLegacyStampRowsCompareSanely pins the migration
// contract documented on gameStamp: pre-upgrade second-truncated rows in
// EARLIER seconds still sort below new-format stamps, so upgrade never
// deletes live data early nor keeps vanished files forever past their
// next rewrite.
func TestReplaceSystemGamesLegacyStampRowsCompareSanely(t *testing.T) {
	s := openTemp(t)
	if err := s.UpsertSystems([]SystemRow{{Key: "nes", Collection: "NES", Bucket: "cartridge", SortOrder: 1, Extensions: `["nes"]`}}); err != nil {
		t.Fatal(err)
	}
	first := time.Now().UTC().Truncate(time.Second).Add(2 * time.Second)
	if err := s.ReplaceSystemGames("nes", []GameRow{
		{RelPath: "Old (Japan).nes", SizeBytes: 7},
	}, first); err != nil {
		t.Fatal(err)
	}
	// Downgrade the row to the legacy shape a pre-ADV-P6-01 binary wrote.
	legacy := first.UTC().Format(time.RFC3339) // second-truncated, no fraction
	if _, err := s.db.Exec(`UPDATE games SET last_seen_at=?, first_seen_at=? WHERE rel_path='Old (Japan).nes'`,
		legacy, legacy); err != nil {
		t.Fatal(err)
	}

	// A superset rescan in a LATER second upserts the row and rewrites it
	// to the new format (live data survives the upgrade boundary).
	if err := s.ReplaceSystemGames("nes", []GameRow{
		{RelPath: "Old (Japan).nes", SizeBytes: 8},
		{RelPath: "New (USA).nes", SizeBytes: 9},
	}, first.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	var stamp string
	if err := s.db.QueryRow(`SELECT last_seen_at FROM games WHERE rel_path='Old (Japan).nes'`).Scan(&stamp); err != nil {
		t.Fatal(err)
	}
	// first was second-truncated, so the rewritten stamp carries the
	// fixed-width zero fraction — unambiguously the new shape, not the
	// bare-second legacy string it replaced.
	if !strings.HasSuffix(stamp, ".000000000Z") || stamp == legacy {
		t.Fatalf("legacy stamp not rewritten to fixed-fraction format: %q (legacy %q)", stamp, legacy)
	}

	// A later subset replace prunes the (now new-format) row normally —
	// and would equally prune a still-legacy row from an earlier second,
	// because "…56Z" < "…57.<frac>Z" holds lexicographically.
	if err := s.ReplaceSystemGames("nes", []GameRow{
		{RelPath: "New (USA).nes", SizeBytes: 9},
	}, first.Add(2*time.Minute)); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM games WHERE system_key='nes'`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("games after subset replace = %d, want 1", n)
	}
}

func TestSetDATInfo(t *testing.T) {
	s := openTemp(t)
	if err := s.UpsertSystems([]SystemRow{{Key: "nes", Collection: "NES", Bucket: "cartridge", SortOrder: 1, Extensions: `["nes"]`}}); err != nil {
		t.Fatal(err)
	}
	if err := s.SetDATInfo(DATInfo{SystemKey: "nes", Filename: "nes.dat", DatName: "NES", Version: "1.0", Date: "2026-08-21", RomCount: 5, SizeBytes: 4096}); err != nil {
		t.Fatal(err)
	}
	// Upsert on rescan.
	if err := s.SetDATInfo(DATInfo{SystemKey: "nes", Filename: "nes.dat", DatName: "NES", Version: "1.1", Date: "2026-09-01", RomCount: 6, SizeBytes: 4100}); err != nil {
		t.Fatal(err)
	}
	got, err := s.DATInfo("nes")
	if err != nil {
		t.Fatal(err)
	}
	if got == nil || got.Version != "1.1" || got.RomCount != 6 {
		t.Errorf("DATInfo = %+v, want version 1.1 roms 6", got)
	}
	if missing, err := s.DATInfo("snes"); err != nil || missing != nil {
		t.Errorf("DATInfo(snes) = %+v, %v; want nil, nil", missing, err)
	}
}

func TestSetScrapeCoverageAndInventory(t *testing.T) {
	s := openTemp(t)
	if err := s.UpsertSystems([]SystemRow{{Key: "nes", Collection: "NES", Bucket: "cartridge", SortOrder: 1, Extensions: `["nes"]`}}); err != nil {
		t.Fatal(err)
	}
	if err := s.SetScrapeCoverage("nes", 3); err != nil {
		t.Fatal(err)
	}
	if err := s.ReplaceInventory([]InventoryRow{{SystemKey: "nes", Count: 5, SizeBytes: 12345, GeneratedAt: "2026-08-21T00:00:00Z"}}); err != nil {
		t.Fatal(err)
	}
	// Absent inventory file on a later scan clears the table (tolerate absence).
	if err := s.ReplaceInventory(nil); err != nil {
		t.Fatal(err)
	}
	var invCount int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM inventory_counts`).Scan(&invCount); err != nil {
		t.Fatal(err)
	}
	if invCount != 0 {
		t.Errorf("inventory rows after nil import = %d, want 0", invCount)
	}
}

func TestRunsLifecycle(t *testing.T) {
	s := openTemp(t)
	id, err := s.StartRun("scan")
	if err != nil {
		t.Fatal(err)
	}
	running, err := s.LastRun()
	if err != nil {
		t.Fatal(err)
	}
	if running == nil || running.Status != "running" || running.FinishedAt != "" {
		t.Fatalf("LastRun while running = %+v", running)
	}
	if err := s.FinishRun(id, "ok", `{"games":13}`); err != nil {
		t.Fatal(err)
	}
	done, err := s.LastRun()
	if err != nil {
		t.Fatal(err)
	}
	if done.Status != "ok" || done.FinishedAt == "" || done.Detail != `{"games":13}` {
		t.Fatalf("LastRun after finish = %+v", done)
	}
	runs, err := s.RecentRuns(10)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 1 {
		t.Fatalf("RecentRuns = %d entries, want 1", len(runs))
	}
}

func TestSystemSummaryJoins(t *testing.T) {
	s := openTemp(t)
	if err := s.UpsertSystems([]SystemRow{
		{Key: "nes", Collection: "NES", Bucket: "cartridge", SortOrder: 1, Extensions: `["nes"]`},
		{Key: "snes", Collection: "SNES", Bucket: "cartridge", SortOrder: 2, Extensions: `["sfc"]`},
	}); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	if err := s.ReplaceSystemGames("nes", []GameRow{{RelPath: "a.nes", SizeBytes: 10}, {RelPath: "b.nes", SizeBytes: 32}}, now); err != nil {
		t.Fatal(err)
	}
	if err := s.SetDATInfo(DATInfo{SystemKey: "nes", Filename: "nes.dat", DatName: "NES", Version: "1.0", Date: "2026-08-21", RomCount: 5}); err != nil {
		t.Fatal(err)
	}
	if err := s.SetScrapeCoverage("nes", 1); err != nil {
		t.Fatal(err)
	}

	rows, err := s.SystemSummary()
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 {
		t.Fatalf("len(SystemSummary) = %d, want 2", len(rows))
	}
	nes := rows[0]
	if nes.Key != "nes" || nes.GameCount != 2 || nes.TotalBytes != 42 {
		t.Errorf("nes summary = %+v", nes)
	}
	if nes.DATDate != "2026-08-21" || nes.DATRomCount != 5 || nes.CacheEntries != 1 {
		t.Errorf("nes dat/cache in summary = %+v", nes)
	}
	if !nes.Active() {
		t.Error("nes should be Active (games>0, dat, cache)")
	}
	snes := rows[1]
	if snes.GameCount != 0 || snes.Active() {
		t.Errorf("snes summary = %+v, want inactive zero row", snes)
	}
}

// ---- P3: verify_results + verify-state transitions + staging -------------

func TestRecordVerifyResultReplacesPrevious(t *testing.T) {
	s := openTemp(t)
	if err := s.UpsertSystems([]SystemRow{{Key: "nes", Collection: "NES", Bucket: "cartridge", SortOrder: 1, Extensions: `["nes"]`}}); err != nil {
		t.Fatal(err)
	}
	if err := s.RecordVerifyResult(VerifyResult{
		SystemKey: "nes", RunID: 1, FinishedAt: "2026-08-21T01:00:00Z",
		DatGames: 5, Found: 3, Missing: 2, Unmatched: 1,
	}); err != nil {
		t.Fatalf("RecordVerifyResult: %v", err)
	}
	// A later run replaces the row — the pill always shows the LATEST report.
	if err := s.RecordVerifyResult(VerifyResult{
		SystemKey: "nes", RunID: 2, FinishedAt: "2026-08-21T02:00:00Z",
		DatGames: 5, Found: 5, Missing: 0, Unmatched: 0, Duplicate: 5, Extra: 2,
		PromotedBytes: 4096,
		ReportPath:    "/scratch/reports/nes.csv",
	}); err != nil {
		t.Fatalf("RecordVerifyResult 2: %v", err)
	}
	rows, err := s.SystemSummary()
	if err != nil {
		t.Fatal(err)
	}
	v := rows[0].Verify
	if !rows[0].VerifyPresent || v.RunID != 2 || v.Found != 5 || v.Missing != 0 || v.PromotedBytes != 4096 {
		t.Errorf("verify_results join = present=%v %+v, want run 2 / 5 found / 0 missing / 4096 B", rows[0].VerifyPresent, v)
	}
	if v.Duplicate != 5 || v.Extra != 2 {
		t.Errorf("provenance counts = dup %d / extra %d, want 5 / 2 (re-verify echoes + tree extras survive the roundtrip)", v.Duplicate, v.Extra)
	}
}

func TestSetSystemVerifyStates(t *testing.T) {
	s := openTemp(t)
	if err := s.UpsertSystems([]SystemRow{{Key: "nes", Collection: "NES", Bucket: "cartridge", SortOrder: 1, Extensions: `["nes"]`}}); err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	if err := s.ReplaceSystemGames("nes", []GameRow{
		{RelPath: "A (USA).nes", SizeBytes: 1},
		{RelPath: "B (USA).nes", SizeBytes: 2},
		{RelPath: "stray.zip", SizeBytes: 3},
	}, now); err != nil {
		t.Fatal(err)
	}

	// A DAT-based verify: A and B claimed by FOUND rows; the stray zip is
	// not covered by the DAT → unmatched (the DAT is authoritative).
	if err := s.SetSystemVerifyStates("nes", []string{"A (USA).nes", "B (USA).nes"}); err != nil {
		t.Fatalf("SetSystemVerifyStates: %v", err)
	}
	var verified, unmatched, unknown int
	if err := s.db.QueryRow(`SELECT
		SUM(CASE WHEN verify_state='verified' THEN 1 ELSE 0 END),
		SUM(CASE WHEN verify_state='unmatched' THEN 1 ELSE 0 END),
		SUM(CASE WHEN verify_state='unknown' THEN 1 ELSE 0 END)
		FROM games WHERE system_key='nes'`).Scan(&verified, &unmatched, &unknown); err != nil {
		t.Fatal(err)
	}
	if verified != 2 || unmatched != 1 || unknown != 0 {
		t.Errorf("states = %d/%d/%d, want 2 verified / 1 unmatched / 0 unknown", verified, unmatched, unknown)
	}

	// A re-verify with a smaller FOUND set degrades yesterday's verified
	// rows — states reflect the LATEST report, never history.
	if err := s.SetSystemVerifyStates("nes", []string{"A (USA).nes"}); err != nil {
		t.Fatalf("SetSystemVerifyStates 2: %v", err)
	}
	if err := s.db.QueryRow(`SELECT
		SUM(CASE WHEN verify_state='verified' THEN 1 ELSE 0 END),
		SUM(CASE WHEN verify_state='unmatched' THEN 1 ELSE 0 END)
		FROM games WHERE system_key='nes'`).Scan(&verified, &unmatched); err != nil {
		t.Fatal(err)
	}
	if verified != 1 || unmatched != 2 {
		t.Errorf("re-verify states = %d/%d, want 1 verified / 2 unmatched", verified, unmatched)
	}

	// States survive a rescan (the schema's standing promise).
	if err := s.ReplaceSystemGames("nes", []GameRow{
		{RelPath: "A (USA).nes", SizeBytes: 1},
		{RelPath: "B (USA).nes", SizeBytes: 2},
		{RelPath: "stray.zip", SizeBytes: 3},
	}, now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	var aState string
	if err := s.db.QueryRow(`SELECT verify_state FROM games WHERE rel_path='A (USA).nes'`).Scan(&aState); err != nil {
		t.Fatal(err)
	}
	_ = unmatched
	if aState != "verified" {
		t.Errorf("verify_state mutated across a rescan: %q", aState)
	}

	// A newly appeared file (promoted after the verify) starts unknown.
	if err := s.ReplaceSystemGames("nes", []GameRow{
		{RelPath: "A (USA).nes", SizeBytes: 1},
		{RelPath: "B (USA).nes", SizeBytes: 2},
		{RelPath: "stray.zip", SizeBytes: 3},
		{RelPath: "C (JP).nes", SizeBytes: 9},
	}, now.Add(2*time.Minute)); err != nil {
		t.Fatal(err)
	}
	var cState string
	if err := s.db.QueryRow(`SELECT verify_state FROM games WHERE rel_path='C (JP).nes'`).Scan(&cState); err != nil {
		t.Fatal(err)
	}
	if cState != "unknown" {
		t.Errorf("newly scanned game verify_state = %q, want unknown", cState)
	}
}

func TestReplaceStaging(t *testing.T) {
	s := openTemp(t)
	if err := s.UpsertSystems([]SystemRow{
		{Key: "nes", Collection: "NES", Bucket: "cartridge", SortOrder: 1, Extensions: `["nes"]`},
		{Key: "snes", Collection: "SNES", Bucket: "cartridge", SortOrder: 2, Extensions: `["sfc"]`},
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.ReplaceStaging([]StagingRow{
		{SystemKey: "nes", Files: 5, Bytes: 1234, InFlight: true},
		{SystemKey: "snes", Files: 0, Bytes: 0},
	}); err != nil {
		t.Fatalf("ReplaceStaging: %v", err)
	}
	got, err := s.StagingRows()
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].SystemKey != "nes" || !got[0].InFlight || got[0].Files != 5 {
		t.Errorf("StagingRows = %+v, want nes in-flight with 5 files + snes zero row", got)
	}
	// Next scan found nothing staged anywhere: the table follows disk.
	if err := s.ReplaceStaging(nil); err != nil {
		t.Fatal(err)
	}
	if got, _ = s.StagingRows(); len(got) != 0 {
		t.Errorf("StagingRows after empty scan = %+v, want none", got)
	}
}

// TestMigrateV1DatabaseStepsToV2 proves a database created by the P1/P2
// schema migrates in place (the VM test host's state dir can survive
// across dev iterations of the webapp package).
func TestMigrateV1DatabaseStepsToV2(t *testing.T) {
	p := filepath.Join(t.TempDir(), "v1.db")
	db, err := sql.Open("sqlite", "file:"+p)
	if err != nil {
		t.Fatal(err)
	}
	for _, stmt := range schemaV1 {
		if _, err := db.Exec(stmt); err != nil {
			t.Fatalf("seed v1 schema: %v", err)
		}
	}
	if _, err := db.Exec(`PRAGMA user_version = 1`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	s, err := Open(p)
	if err != nil {
		t.Fatalf("Open v1 database: %v", err)
	}
	defer s.Close() //nolint:errcheck // test
	if got := s.SchemaVersion(); got != SchemaVersion {
		t.Fatalf("migrated user_version = %d, want %d", got, SchemaVersion)
	}
	// The v2 tables are usable post-migration.
	if err := s.UpsertSystems([]SystemRow{{Key: "nes", Collection: "NES", Bucket: "cartridge", SortOrder: 1, Extensions: `["nes"]`}}); err != nil {
		t.Fatal(err)
	}
	if err := s.RecordVerifyResult(VerifyResult{SystemKey: "nes", RunID: 9, DatGames: 1, Found: 1}); err != nil {
		t.Fatalf("RecordVerifyResult on migrated db: %v", err)
	}
}

// TestMigrateV2DatabaseStepsToV3 proves a database from the first P3 cut
// (verify_results without the provenance-split extra column, e.g. a dev
// VM's surviving state dir) migrates in place, keeping its rows.
func TestMigrateV2DatabaseStepsToV3(t *testing.T) {
	p := filepath.Join(t.TempDir(), "v2.db")
	db, err := sql.Open("sqlite", "file:"+p)
	if err != nil {
		t.Fatal(err)
	}
	for _, stmt := range append(append([]string{}, schemaV1...), schemaV2...) {
		if _, err := db.Exec(stmt); err != nil {
			t.Fatalf("seed v2 schema: %v", err)
		}
	}
	if _, err := db.Exec(`INSERT INTO systems (key, collection, bucket, sort_order) VALUES ('nes', 'NES', 'cartridge', 1)`); err != nil {
		t.Fatal(err)
	}
	// A pre-v3 row: no extra column exists yet.
	if _, err := db.Exec(`INSERT INTO verify_results
		(system_key, run_id, finished_at, dat_games, found, missing, unmatched, duplicate, other, promoted_bytes, unchecked, report_path)
		VALUES ('nes', 7, '2026-08-21T00:00:00Z', 5, 5, 0, 0, 5, 0, 0, 0, '/r/nes.csv')`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`PRAGMA user_version = 2`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	s, err := Open(p)
	if err != nil {
		t.Fatalf("Open v2 database: %v", err)
	}
	defer s.Close() //nolint:errcheck // test
	if got := s.SchemaVersion(); got != SchemaVersion {
		t.Fatalf("migrated user_version = %d, want %d", got, SchemaVersion)
	}
	rows, err := s.SystemSummary()
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || !rows[0].VerifyPresent || rows[0].Verify.Found != 5 || rows[0].Verify.Extra != 0 {
		t.Errorf("pre-v3 row lost or mangled by migration: %+v", rows)
	}
}

// TestMigrateV6DatabaseStepsToV7 pins the P6 artifact column: a pre-v7
// verify_results row (no artifacts column) migrates cleanly and reads as
// "0 artifacts"; a fresh RecordVerifyResult roundtrips the count through
// the summary join.
func TestMigrateV6DatabaseStepsToV7(t *testing.T) {
	p := filepath.Join(t.TempDir(), "v6.db")
	db, err := sql.Open("sqlite", "file:"+p)
	if err != nil {
		t.Fatal(err)
	}
	steps := []string{}
	steps = append(steps, schemaV1...)
	steps = append(steps, schemaV2...)
	steps = append(steps, schemaV3...)
	steps = append(steps, schemaV4...)
	steps = append(steps, schemaV5...)
	steps = append(steps, schemaV6...)
	for _, stmt := range steps {
		if _, err := db.Exec(stmt); err != nil && !strings.Contains(err.Error(), "already exists") {
			t.Fatalf("seed schema: %v", err)
		}
	}
	if _, err := db.Exec(`INSERT INTO systems (key, collection, bucket, sort_order) VALUES ('nes', 'NES', 'cartridge', 1)`); err != nil {
		t.Fatal(err)
	}
	// A v6-shaped row: extra exists (v3), artifacts does not (v7).
	if _, err := db.Exec(`INSERT INTO verify_results
		(system_key, run_id, finished_at, dat_games, found, missing, unmatched, duplicate, other, extra, promoted_bytes, unchecked, report_path)
		VALUES ('nes', 9, '2026-08-22T00:00:00Z', 4, 4, 0, 0, 4, 0, 2, 0, 0, '/r/nes.csv')`); err != nil {
		t.Fatalf("seed v6 row: %v", err)
	}
	if _, err := db.Exec(`PRAGMA user_version = 6`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	s, err := Open(p)
	if err != nil {
		t.Fatalf("Open v6 database: %v", err)
	}
	defer s.Close() //nolint:errcheck // test
	if got := s.SchemaVersion(); got != SchemaVersion {
		t.Fatalf("migrated user_version = %d, want %d", got, SchemaVersion)
	}
	rows, err := s.SystemSummary()
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].Verify.Extra != 2 || rows[0].Verify.Artifacts != 0 {
		t.Errorf("pre-v7 row lost/mangled by migration: %+v", rows)
	}

	// Roundtrip: the artifact counter persists through the upsert + join.
	if err := s.RecordVerifyResult(VerifyResult{
		SystemKey: "nes", RunID: 10, FinishedAt: "2026-08-23T00:00:00Z",
		DatGames: 4, Found: 4, Artifacts: 3,
	}); err != nil {
		t.Fatalf("RecordVerifyResult: %v", err)
	}
	rows, _ = s.SystemSummary()
	if len(rows) != 1 || rows[0].Verify.Artifacts != 3 {
		t.Errorf("artifacts not persisted/read: %+v", rows)
	}
}

// ---- P4: library browsing (ListGames / GetGame) ---------------------------

func TestGameQueries(t *testing.T) {
	s := openTemp(t)
	systems := []SystemRow{
		{Key: "nes", Collection: "NES", Bucket: "cartridge", SortOrder: 1, Extensions: `["nes"]`},
		{Key: "snes", Collection: "Super Nintendo", Bucket: "cartridge", SortOrder: 2, Extensions: `["smc"]`},
		{Key: "gb", Collection: "Game Boy", Bucket: "cartridge", SortOrder: 3, Extensions: `["gb"]`},
	}
	if err := s.UpsertSystems(systems); err != nil {
		t.Fatalf("UpsertSystems: %v", err)
	}
	now := time.Now().UTC()
	perSystem := make([][]GameRow, len(systems))
	for i := 0; i < 2500; i++ {
		perSystem[i%len(systems)] = append(perSystem[i%len(systems)],
			GameRow{RelPath: fmt.Sprintf("Game %04d", i), SizeBytes: int64(i) * 100})
	}
	for si, rows := range perSystem {
		if err := s.ReplaceSystemGames(systems[si].Key, rows, now); err != nil {
			t.Fatalf("ReplaceSystemGames(%s): %v", systems[si].Key, err)
		}
	}

	// Pagination: 2500 rows at limit 100 → 25 pages, every id exactly once,
	// last page holding the Total%limit remainder.
	seen := map[int64]bool{}
	pages, lastLen := 0, 0
	for offset := 0; pages <= 100; offset += 100 {
		page, err := s.ListGames(GameListOpts{Limit: 100, Offset: offset})
		if err != nil {
			t.Fatalf("ListGames offset %d: %v", offset, err)
		}
		if page.Total != 2500 {
			t.Fatalf("page.Total at offset %d = %d, want 2500", offset, page.Total)
		}
		if len(page.Games) == 0 {
			break
		}
		pages++
		lastLen = len(page.Games)
		for _, g := range page.Games {
			if seen[g.ID] {
				t.Fatalf("duplicate game id %d across pages", g.ID)
			}
			seen[g.ID] = true
		}
	}
	if pages > 100 {
		t.Fatal("pagination never terminated")
	}
	wantLast := 2500 % 100
	if wantLast == 0 {
		wantLast = 100
	}
	if pages != 25 || len(seen) != 2500 {
		t.Errorf("paged through %d pages / %d unique ids, want 25 / 2500", pages, len(seen))
	}
	if lastLen != wantLast {
		t.Errorf("last page has %d rows, want %d", lastLen, wantLast)
	}

	// q filters case-insensitively. FTS5 matches case-folded TOKEN
	// prefixes and LIKE whole substrings (see store.go's semantics note);
	// "GaMe 00" yields the same 100 rows under either backend.
	page, err := s.ListGames(GameListOpts{Q: "GaMe 00"})
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("search backend fts=%v; q=%q hits=%d", s.FTSSearchEnabled(), "GaMe 00", page.Total)
	if page.Total != 100 || len(page.Games) != 100 {
		t.Errorf(`Q="GaMe 00" total = %d (%d rows), want 100 (Game 0000..0099)`, page.Total, len(page.Games))
	}

	// systemKey filter returns only that system's rows.
	page, err = s.ListGames(GameListOpts{SystemKey: "snes"})
	if err != nil {
		t.Fatal(err)
	}
	if page.Total != 833 || len(page.Games) != 833 {
		t.Errorf("systemKey=snes total = %d (%d rows), want 833", page.Total, len(page.Games))
	}
	for _, g := range page.Games {
		if g.SystemKey != "snes" {
			t.Fatalf("systemKey filter leaked a %q row (%q)", g.SystemKey, g.RelPath)
		}
	}

	// verifyState filter.
	if err := s.SetSystemVerifyStates("nes", []string{"Game 0000", "Game 0003"}); err != nil {
		t.Fatalf("SetSystemVerifyStates: %v", err)
	}
	page, err = s.ListGames(GameListOpts{VerifyState: "verified"})
	if err != nil {
		t.Fatal(err)
	}
	if page.Total != 2 {
		t.Errorf("verifyState=verified total = %d, want 2", page.Total)
	}
	for _, g := range page.Games {
		if g.VerifyState != "verified" {
			t.Errorf("verifyState filter leaked %q as %q", g.RelPath, g.VerifyState)
		}
	}

	// hidden filter.
	if _, err := s.db.Exec(`UPDATE games SET hidden=1 WHERE rel_path='Game 0001'`); err != nil {
		t.Fatal(err)
	}
	notHidden := false
	page, err = s.ListGames(GameListOpts{Hidden: &notHidden})
	if err != nil {
		t.Fatal(err)
	}
	if page.Total != 2499 {
		t.Errorf("hidden=false total = %d, want 2499", page.Total)
	}
	isHidden := true
	page, err = s.ListGames(GameListOpts{Hidden: &isHidden})
	if err != nil {
		t.Fatal(err)
	}
	if page.Total != 1 || len(page.Games) != 1 || page.Games[0].RelPath != "Game 0001" {
		t.Errorf("hidden=true = %d rows %+v, want just Game 0001", page.Total, page.Games)
	}

	// sort=title orders case-insensitively ascending.
	page, err = s.ListGames(GameListOpts{Sort: SortTitle})
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Games) != 2500 || page.Games[0].RelPath != "Game 0000" {
		t.Errorf("title sort first = %q of %d rows", page.Games[0].RelPath, len(page.Games))
	}
	for i := 1; i < len(page.Games); i++ {
		prev, cur := page.Games[i-1].RelPath, page.Games[i].RelPath
		if strings.ToLower(prev) > strings.ToLower(cur) {
			t.Fatalf("title order broken at %d: %q > %q", i, prev, cur)
		}
	}

	// sort=size orders biggest first.
	page, err = s.ListGames(GameListOpts{Sort: SortSize})
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Games) != 2500 || page.Games[0].SizeBytes != 249900 {
		t.Errorf("size sort first = %d of %d rows, want 249900", page.Games[0].SizeBytes, len(page.Games))
	}
	for i := 1; i < len(page.Games); i++ {
		if page.Games[i-1].SizeBytes < page.Games[i].SizeBytes {
			t.Fatalf("size order broken at %d: %d < %d", i, page.Games[i-1].SizeBytes, page.Games[i].SizeBytes)
		}
	}

	// GetGame returns the row joined with its system; identity is
	// (system, id) — absent pairs read as nil, not an error.
	hit, err := s.ListGames(GameListOpts{Q: "Game 0010"})
	if err != nil || hit.Total != 1 {
		t.Fatalf("lookup Game 0010: total=%d, %v", hit.Total, err)
	}
	row := hit.Games[0]
	got, err := s.GetGame(row.SystemKey, row.ID)
	if err != nil || got == nil {
		t.Fatalf("GetGame(%s,%d) = %+v, %v", row.SystemKey, row.ID, got, err)
	}
	if got.RelPath != "Game 0010" || got.System.Key != row.SystemKey || got.System.Collection != "Super Nintendo" {
		t.Errorf("GetGame detail = %q / system %+v, want Game 0010 / Super Nintendo", got.RelPath, got.System)
	}
	if missing, err := s.GetGame(row.SystemKey, 99999999); err != nil || missing != nil {
		t.Errorf("GetGame bogus id = %+v, %v; want nil, nil (absent)", missing, err)
	}
	if wrongSys, err := s.GetGame("gb", row.ID); err != nil || wrongSys != nil {
		t.Errorf("GetGame valid id under wrong system = %+v, %v; want nil, nil", wrongSys, err)
	}
}

// ---- P4: unmatched-file persistence + verify history ----------------------

// TestVerifyUnmatched covers the v4 migration (a pre-v4 database's seeded
// verify_results row survives reopen and the new table is usable), the
// record/readback/replace roundtrip, FK cascade cleanup, and the
// newest-first capped verify history.
func TestVerifyUnmatched(t *testing.T) {
	// Seed a v3 database with one system + its last-verify aggregate.
	p := filepath.Join(t.TempDir(), "v3.db")
	db, err := sql.Open("sqlite", "file:"+p)
	if err != nil {
		t.Fatal(err)
	}
	v3Schema := append(append(append([]string{}, schemaV1...), schemaV2...), schemaV3...)
	for _, stmt := range v3Schema {
		if _, err := db.Exec(stmt); err != nil {
			t.Fatalf("seed v3 schema: %v", err)
		}
	}
	if _, err := db.Exec(`INSERT INTO systems (key, collection, bucket, sort_order) VALUES ('nes', 'NES', 'cartridge', 1)`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO verify_results
		(system_key, run_id, finished_at, dat_games, found, missing, unmatched, duplicate, other, promoted_bytes, unchecked, report_path)
		VALUES ('nes', 7, '2026-08-21T00:00:00Z', 5, 5, 0, 2, 0, 0, 0, 0, '/r/nes.csv')`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`PRAGMA user_version = 3`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	s, err := Open(p)
	if err != nil {
		t.Fatalf("Open v3 database: %v", err)
	}
	defer s.Close() //nolint:errcheck // test
	if got := s.SchemaVersion(); got != SchemaVersion {
		t.Fatalf("migrated user_version = %d, want %d", got, SchemaVersion)
	}
	rows, err := s.SystemSummary()
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || !rows[0].VerifyPresent || rows[0].Verify.RunID != 7 || rows[0].Verify.Unmatched != 2 {
		t.Fatalf("pre-v4 verify_results lost or mangled by migration: %+v", rows)
	}

	// Roundtrip: filenames read back sorted regardless of insert order.
	files := []string{"b.zip", "a.bin"}
	if err := s.RecordVerifyUnmatched("nes", 7, files); err != nil {
		t.Fatalf("RecordVerifyUnmatched: %v", err)
	}
	got, err := s.VerifyUnmatched(7, "nes")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0] != "a.bin" || got[1] != "b.zip" {
		t.Errorf("VerifyUnmatched = %v, want [a.bin b.zip]", got)
	}

	// Replace: a newer run wipes the previous list for the system.
	if err := s.RecordVerifyUnmatched("nes", 8, []string{"c.iso"}); err != nil {
		t.Fatalf("RecordVerifyUnmatched replace: %v", err)
	}
	if old, err := s.VerifyUnmatched(7, "nes"); err != nil || len(old) != 0 {
		t.Errorf("old run after replace = %v, %v; want empty", old, err)
	}
	if cur, err := s.VerifyUnmatched(8, "nes"); err != nil || len(cur) != 1 || cur[0] != "c.iso" {
		t.Errorf("current run = %v, %v; want [c.iso]", cur, err)
	}

	// FK cascade: dropping the system clears its unmatched rows.
	if err := s.UpsertSystems([]SystemRow{{Key: "snes", Collection: "SNES", Bucket: "cartridge", SortOrder: 2, Extensions: `["sfc"]`}}); err != nil {
		t.Fatal(err)
	}
	if left, err := s.VerifyUnmatched(8, "nes"); err != nil || len(left) != 0 {
		t.Errorf("rows survived system delete: %v, %v", left, err)
	}
	if err := s.UpsertSystems([]SystemRow{
		{Key: "nes", Collection: "NES", Bucket: "cartridge", SortOrder: 1, Extensions: `["nes"]`},
		{Key: "snes", Collection: "SNES", Bucket: "cartridge", SortOrder: 2, Extensions: `["sfc"]`},
	}); err != nil {
		t.Fatal(err)
	}

	// History: three verify runs for nes (plus a decoy scan run and a
	// snes-only verify run that must both be skipped), newest first,
	// capped at n.
	verifyDetail := func(found, unmatched, extra int) string {
		return fmt.Sprintf(`{"Systems":[{"Sys":"snes","Outcome":"verified","Found":9,"Unmatched":0,"Extra":0},`+
			`{"Sys":"nes","Outcome":"verified","Found":%d,"Unmatched":%d,"Extra":%d}],"Promoted":false}`, found, unmatched, extra)
	}
	var ids []int64
	for i, counts := range [][3]int{{5, 2, 1}, {6, 1, 1}, {7, 0, 0}} { // oldest → newest
		id, err := s.StartRun("verify")
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, id)
		if err := s.FinishRun(id, "ok", verifyDetail(counts[0], counts[1], counts[2])); err != nil {
			t.Fatal(err)
		}
		if i == 1 { // interleave decoys mid-sequence
			scanID, err := s.StartRun("scan")
			if err != nil {
				t.Fatal(err)
			}
			if err := s.FinishRun(scanID, "ok", verifyDetail(99, 99, 99)); err != nil {
				t.Fatal(err)
			}
		}
	}

	hist, err := s.SystemVerifyHistory("nes", 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(hist) != 2 {
		t.Fatalf("history cap n=2 gave %d points, want 2", len(hist))
	}
	wantNewest := VerifyRunPoint{FinishedAt: hist[0].FinishedAt, Found: 7, Unmatched: 0, Extra: 0}
	if hist[0] != wantNewest {
		t.Errorf("newest point = %+v, want %+v", hist[0], wantNewest)
	}
	if hist[1].Found != 6 || hist[1].Unmatched != 1 || hist[1].Extra != 1 {
		t.Errorf("second-newest point = %+v, want run %d's outcome (6/1/1)", hist[1], ids[1])
	}
	all, err := s.SystemVerifyHistory("nes", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 3 || all[2].Found != 5 || all[2].Unmatched != 2 || all[2].Extra != 1 {
		t.Errorf("full history = %+v, want 3 points oldest-first ending at run %d (5/2/1)", all, ids[0])
	}
	if none, err := s.SystemVerifyHistory("gb", 10); err != nil || len(none) != 0 {
		t.Errorf("history for unknown system = %v, %v; want empty", none, err)
	}
	if zero, _ := s.SystemVerifyHistory("nes", 0); len(zero) != 0 {
		t.Errorf("n=0 gave %v, want empty", zero)
	}
}

// ---- P5: metadata-engine columns -------------------------------------------

// TestScrapeFlagsAndChecksums covers the v5 migration (a pre-v5 database's
// seeded games row survives reopen and reads as unscraped/unchecked), the
// full-replace semantics of SetSystemScrapeFlags, the selective
// (never-clobber) SetGameChecksums update, and GetGame's exposure of all
// four new fields.
func TestScrapeFlagsAndChecksums(t *testing.T) {
	// Seed a v4 database with one system + one game row.
	p := filepath.Join(t.TempDir(), "v4.db")
	db, err := sql.Open("sqlite", "file:"+p)
	if err != nil {
		t.Fatal(err)
	}
	v4Schema := append(append(append(append([]string{}, schemaV1...), schemaV2...), schemaV3...), schemaV4...)
	for _, stmt := range v4Schema {
		if _, err := db.Exec(stmt); err != nil {
			t.Fatalf("seed v4 schema: %v", err)
		}
	}
	if _, err := db.Exec(`INSERT INTO systems (key, collection, bucket, sort_order) VALUES ('nes', 'NES', 'cartridge', 1)`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO games (system_key, rel_path, size_bytes, first_seen_at, last_seen_at)
		VALUES ('nes', 'A (USA).nes', 1024, '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`PRAGMA user_version = 4`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	s, err := Open(p)
	if err != nil {
		t.Fatalf("Open v4 database: %v", err)
	}
	defer s.Close() //nolint:errcheck // test
	if got := s.SchemaVersion(); got != SchemaVersion {
		t.Fatalf("migrated user_version = %d, want %d", got, SchemaVersion)
	}

	page, err := s.ListGames(GameListOpts{})
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Games) != 1 || page.Games[0].RelPath != "A (USA).nes" {
		t.Fatalf("pre-v5 games lost or mangled by migration: %+v", page.Games)
	}

	// GetGame reads the fresh columns as zero-value (unscraped).
	d, err := s.GetGame("nes", page.Games[0].ID)
	if err != nil || d == nil {
		t.Fatalf("GetGame: %v, %v", d, err)
	}
	if d.HasDescription || d.HasCover || d.CRC32 != "" || d.SHA1 != "" {
		t.Errorf("fresh columns = %+v, want zero-value (unscraped)", d)
	}

	// Scrape flags: two positives land.
	if err := s.SetSystemScrapeFlags("nes", []GameScrapeFlag{
		{RelPath: "A (USA).nes", Description: true},
		{RelPath: "B (Europe).zip", Cover: true}, // unknown rel_path: no-op
	}); err != nil {
		t.Fatalf("SetSystemScrapeFlags: %v", err)
	}
	d, _ = s.GetGame("nes", page.Games[0].ID)
	if !d.HasDescription || d.HasCover {
		t.Errorf("flags after set = desc:%v cover:%v, want desc:true cover:false", d.HasDescription, d.HasCover)
	}

	// Full-replace: a recompute that no longer claims the game clears it.
	if err := s.SetSystemScrapeFlags("nes", []GameScrapeFlag{}); err != nil {
		t.Fatalf("SetSystemScrapeFlags replace: %v", err)
	}
	d, _ = s.GetGame("nes", page.Games[0].ID)
	if d.HasDescription || d.HasCover {
		t.Errorf("flags after clear = %+v, want both false (full-replace)", d)
	}

	// Checksums are selective: a partial row must not erase prior data.
	if err := s.SetGameChecksums("nes", []GameChecksum{{RelPath: "A (USA).nes", CRC32: "deadbeef", SHA1: "aaa111"}}); err != nil {
		t.Fatalf("SetGameChecksums: %v", err)
	}
	if err := s.SetGameChecksums("nes", []GameChecksum{{RelPath: "A (USA).nes", SHA1: "bbb222"}}); err != nil {
		t.Fatalf("SetGameChecksums partial: %v", err)
	}
	d, _ = s.GetGame("nes", page.Games[0].ID)
	if d.CRC32 != "deadbeef" || d.SHA1 != "bbb222" {
		t.Errorf("checksums after selective update = %s/%s, want deadbeef/bbb222", d.CRC32, d.SHA1)
	}
	// Empty fields on an unknown rel path stay harmless no-ops.
	if err := s.SetGameChecksums("nes", []GameChecksum{{RelPath: "nope.nes"}}); err != nil {
		t.Fatalf("SetGameChecksums unknown rel: %v", err)
	}
}

// ---- P6: enrichment columns + generation queries ---------------------------

func seedP6Store(t *testing.T) *Store {
	t.Helper()
	s := openTemp(t)
	if err := s.UpsertSystems([]SystemRow{
		{Key: "nes", Collection: "Nintendo Entertainment System", Bucket: "cartridge", Core: "fceumm", SortOrder: 1, Extensions: `["nes"]`},
	}); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	if err := s.ReplaceSystemGames("nes", []GameRow{
		{RelPath: "B Second (USA).nes", SizeBytes: 2},
		{RelPath: "A First (USA).nes", SizeBytes: 1},
		{RelPath: "C Hidden (USA).nes", SizeBytes: 3},
	}, now); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec(`UPDATE games SET hidden=1 WHERE rel_path='C Hidden (USA).nes'`); err != nil {
		t.Fatal(err)
	}
	return s
}

// TestGameMetaRoundTrip pins the generator's read side (hidden excluded,
// catalogue-stable order) and the selective write side.
func TestGameMetaRoundTrip(t *testing.T) {
	s := seedP6Store(t)

	rows, err := s.SystemGamesWithMeta("nes")
	if err != nil {
		t.Fatalf("SystemGamesWithMeta: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("rows = %d, want 2 (hidden row must be excluded)", len(rows))
	}
	if rows[0].RelPath != "A First (USA).nes" || rows[1].RelPath != "B Second (USA).nes" {
		t.Fatalf("rows not rel_path-ordered: %q, %q", rows[0].RelPath, rows[1].RelPath)
	}
	if rows[0].Description != "" || rows[0].Rating != "" {
		t.Fatalf("absent meta must read as empty strings, got %+v", rows[0])
	}

	// Selective set: one game fully enriched, the other untouched.
	err = s.SetGameMeta("nes", []GameMeta{
		{RelPath: "A First (USA).nes", Description: "First!", Release: "1987", Developer: "D", Publisher: "P", Genre: "Platform", Rating: "E"},
	})
	if err != nil {
		t.Fatalf("SetGameMeta: %v", err)
	}
	rows, _ = s.SystemGamesWithMeta("nes")
	got := map[string]GameMetaRow{}
	for _, r := range rows {
		got[r.RelPath] = r
	}
	a := got["A First (USA).nes"]
	if a.Description != "First!" || a.Release != "1987" || a.Developer != "D" || a.Publisher != "P" || a.Genre != "Platform" || a.Rating != "E" {
		t.Fatalf("enrichment lost: %+v", a)
	}
	b := got["B Second (USA).nes"]
	if b.Description != "" {
		t.Fatalf("untouched game gained description %q", b.Description)
	}

	// Partial update keeps stored values (empty leaves untouched), like
	// SetGameChecksums — an ingest that only knows the genre cannot wipe
	// the description.
	if err := s.SetGameMeta("nes", []GameMeta{{RelPath: "A First (USA).nes", Genre: "Puzzle"}}); err != nil {
		t.Fatalf("SetGameMeta partial: %v", err)
	}
	rows, _ = s.SystemGamesWithMeta("nes")
	if rows[0].Description != "First!" || rows[0].Genre != "Puzzle" {
		t.Fatalf("partial update clobbered fields: %+v", rows[0])
	}
}

// TestRunsByKind backs the generation log section: kind-filtered runs,
// newest first, other kinds invisible.
func TestRunsByKind(t *testing.T) {
	s := openTemp(t)
	id1, _ := s.StartRun("scan")
	_ = s.FinishRun(id1, "ok", "")
	id2, _ := s.StartRun("generate")
	_ = s.FinishRun(id2, "ok", `{"Systems":[]}`)
	id3, _ := s.StartRun("generate")
	_ = s.FinishRun(id3, "error", "boom")

	runs, err := s.RunsByKind("generate", 10)
	if err != nil {
		t.Fatalf("RunsByKind: %v", err)
	}
	if len(runs) != 2 {
		t.Fatalf("runs = %d, want 2 generate-only rows", len(runs))
	}
	if runs[0].Status != "error" || runs[1].Status != "ok" {
		t.Fatalf("runs not newest-first or wrong kinds: %+v", runs)
	}
}

// TestMigrateV5DatabaseStepsToV6 proves an existing P5 database gains the
// enrichment columns in place (the VM's surviving state dirs).
func TestMigrateV5DatabaseStepsToV6(t *testing.T) {
	p := filepath.Join(t.TempDir(), "v5.db")
	db, err := sql.Open("sqlite", "file:"+p)
	if err != nil {
		t.Fatal(err)
	}
	for _, stmt := range append(append([]string{}, schemaV1...), append(append(append(schemaV2, schemaV3...), schemaV4...), schemaV5...)...) {
		if _, err := db.Exec(stmt); err != nil {
			t.Fatalf("seed v5 schema: %v", err)
		}
	}
	if _, err := db.Exec(`PRAGMA user_version = 5`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	s, err := Open(p)
	if err != nil {
		t.Fatalf("Open v5 database: %v", err)
	}
	defer s.Close() //nolint:errcheck // test
	if got := s.SchemaVersion(); got != SchemaVersion {
		t.Fatalf("migrated user_version = %d, want %d", got, SchemaVersion)
	}
	// The new columns are usable post-migration.
	if err := s.UpsertSystems([]SystemRow{{Key: "nes", Collection: "NES", Bucket: "cartridge", SortOrder: 1}}); err != nil {
		t.Fatal(err)
	}
	if err := s.ReplaceSystemGames("nes", []GameRow{{RelPath: "A.nes", SizeBytes: 1}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := s.SetGameMeta("nes", []GameMeta{{RelPath: "A.nes", Description: "post-migration"}}); err != nil {
		t.Fatalf("SetGameMeta on migrated db: %v", err)
	}
}

// TestSetGameHidden pins the curation flag write (P6 generator contract:
// hidden=true rows are excluded from generation; P7's UI flips it).
func TestSetGameHidden(t *testing.T) {
	s := seedP6Store(t)
	if err := s.SetGameHidden("nes", "A First (USA).nes", true); err != nil {
		t.Fatalf("SetGameHidden: %v", err)
	}
	rows, _ := s.SystemGamesWithMeta("nes")
	if len(rows) != 1 || rows[0].RelPath != "B Second (USA).nes" {
		t.Fatalf("hidden row still visible to generation: %+v", rows)
	}
	page, err := s.ListGames(GameListOpts{SystemKey: "nes", Hidden: func() *bool { b := false; return &b }()})
	if err != nil {
		t.Fatal(err)
	}
	_ = page
	if err := s.SetGameHidden("nes", "A First (USA).nes", false); err != nil {
		t.Fatalf("unhide: %v", err)
	}
	rows, _ = s.SystemGamesWithMeta("nes")
	if len(rows) != 2 {
		t.Fatalf("unhide did not restore visibility: %d rows", len(rows))
	}
	// Unknown rel path: a harmless no-op (idempotent curation), not an error.
	if err := s.SetGameHidden("nes", "Nope.nes", true); err != nil {
		t.Fatalf("unknown rel path must be a no-op, got %v", err)
	}
}

// ---- P7: custom collections -------------------------------------------------

// TestMigrateV7DatabaseStepsToV8 pins the P7 tables: a pre-v8 database
// migrates in place, keeps its rows, and the new CRUD round-trips.
func TestMigrateV7DatabaseStepsToV8(t *testing.T) {
	p := filepath.Join(t.TempDir(), "v7.db")
	db, err := sql.Open("sqlite", "file:"+p)
	if err != nil {
		t.Fatal(err)
	}
	steps := []string{}
	steps = append(steps, schemaV1...)
	steps = append(steps, schemaV2...)
	steps = append(steps, schemaV3...)
	steps = append(steps, schemaV4...)
	steps = append(steps, schemaV5...)
	steps = append(steps, schemaV6...)
	steps = append(steps, schemaV7...)
	for _, stmt := range steps {
		if _, err := db.Exec(stmt); err != nil && !strings.Contains(err.Error(), "already exists") {
			t.Fatalf("seed v7 schema: %v", err)
		}
	}
	if _, err := db.Exec(`INSERT INTO systems (key, collection, bucket, sort_order) VALUES ('nes', 'NES', 'cartridge', 1)`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`PRAGMA user_version = 7`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	s, err := Open(p)
	if err != nil {
		t.Fatalf("Open v7 database: %v", err)
	}
	defer s.Close() //nolint:errcheck // test
	if got := s.SchemaVersion(); got != SchemaVersion {
		t.Fatalf("migrated user_version = %d, want %d", got, SchemaVersion)
	}
	cols, err := s.Collections()
	if err != nil || len(cols) != 0 {
		t.Fatalf("fresh Collections() = %+v, %v; want empty", cols, err)
	}
}

// TestCollectionsCRUD pins the P7 store surface: shortname derivation and
// collision probing, rename keeping the shortname stable, member
// add/remove idempotence with identity checks, cascade delete, and
// deterministic member ordering.
func TestCollectionsCRUD(t *testing.T) {
	s := seedP6Store(t)
	// One batch — UpsertSystems REPLACES the table and cascades away any
	// system omitted from the list (ADV-P1-03's delete semantics).
	if err := s.UpsertSystems([]SystemRow{
		{Key: "nes", Collection: "Nintendo Entertainment System", Bucket: "cartridge", Core: "fceumm", SortOrder: 1, Extensions: `["nes"]`},
		{Key: "snes", Collection: "Super NES", Bucket: "cartridge", Core: "snes9x", SortOrder: 2, Extensions: `["sfc"]`},
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.ReplaceSystemGames("snes", []GameRow{{RelPath: "D Snes Game (USA).sfc", SizeBytes: 4}}, time.Now()); err != nil {
		t.Fatal(err)
	}

	id, err := s.CreateCollection("Kitchen Quick-Play!", "pick up and play")
	if err != nil {
		t.Fatalf("CreateCollection: %v", err)
	}
	col, err := s.Collection(id)
	if err != nil || col == nil {
		t.Fatalf("Collection(%d) = %+v, %v; want row", id, col, err)
	}
	if col.Shortname != "kitchen-quick-play" || col.Summary != "pick up and play" || col.Name != "Kitchen Quick-Play!" {
		t.Fatalf("created collection wrong: %+v", col)
	}

	// Shortname collision probing: same name again → -2 suffix, no error.
	id2, err := s.CreateCollection("Kitchen Quick-Play!", "")
	if err != nil {
		t.Fatalf("CreateCollection duplicate name: %v", err)
	}
	col2, _ := s.Collection(id2)
	if col2 == nil || col2.Shortname != "kitchen-quick-play-2" {
		t.Fatalf("collision probe wrong: %+v", col2)
	}
	if err := s.DeleteCollection(id2); err != nil {
		t.Fatal(err)
	}

	// Membership: cross-system, idempotent, identity-checked.
	games, err := s.ListGames(GameListOpts{Limit: 10})
	if err != nil {
		t.Fatal(err)
	}
	var nesA, snesD GameSummary
	for _, g := range games.Games {
		switch g.RelPath {
		case "A First (USA).nes":
			nesA = g
		case "D Snes Game (USA).sfc":
			snesD = g
		}
	}
	if nesA.ID == 0 || snesD.ID == 0 {
		t.Fatal("fixture games missing")
	}
	if err := s.AddCollectionGame(id, "nes", nesA.ID); err != nil {
		t.Fatalf("AddCollectionGame nes: %v", err)
	}
	if err := s.AddCollectionGame(id, "nes", nesA.ID); err != nil {
		t.Fatalf("re-add must be idempotent: %v", err)
	}
	if err := s.AddCollectionGame(id, "snes", snesD.ID); err != nil {
		t.Fatalf("AddCollectionGame snes (cross-system): %v", err)
	}
	// Wrong system for the id → rejected (identity is (system, id)).
	if err := s.AddCollectionGame(id, "snes", nesA.ID); err == nil {
		t.Fatal("add accepted a game under the WRONG system key")
	}
	members, err := s.CollectionMembers(id)
	if err != nil {
		t.Fatal(err)
	}
	if len(members) != 2 {
		t.Fatalf("members = %d, want 2", len(members))
	}
	if members[0].SystemKey != "nes" || members[1].SystemKey != "snes" {
		t.Fatalf("member order not (position, system, rel_path)-deterministic: %+v", members)
	}
	col, _ = s.Collection(id)
	if col.Games != 2 {
		t.Fatalf("member count = %d, want 2", col.Games)
	}

	// Hidden members stay listed for the editor but are flagged.
	if err := s.SetGameHidden("nes", "A First (USA).nes", true); err != nil {
		t.Fatal(err)
	}
	members, _ = s.CollectionMembers(id)
	if len(members) != 2 || !members[0].Hidden {
		t.Fatalf("hidden member not flagged for the editor: %+v", members)
	}
	if err := s.SetGameHidden("nes", "A First (USA).nes", false); err != nil {
		t.Fatal(err)
	}

	// Rename keeps the shortname (stable launcher-DB identity).
	if err := s.UpdateCollection(id, "Late Night Set", "after dark"); err != nil {
		t.Fatal(err)
	}
	col, _ = s.Collection(id)
	if col.Name != "Late Night Set" || col.Summary != "after dark" || col.Shortname != "kitchen-quick-play" {
		t.Fatalf("rename mangled the collection: %+v", col)
	}

	// Remove one member; removing a non-member is a no-op.
	if err := s.RemoveCollectionGame(id, "snes", snesD.ID); err != nil {
		t.Fatal(err)
	}
	if err := s.RemoveCollectionGame(id, "snes", snesD.ID); err != nil {
		t.Fatalf("remove of non-member must be a no-op: %v", err)
	}
	members, _ = s.CollectionMembers(id)
	if len(members) != 1 {
		t.Fatalf("members after remove = %d, want 1", len(members))
	}

	// Delete cascades the memberships away.
	if err := s.DeleteCollection(id); err != nil {
		t.Fatal(err)
	}
	if col, _ := s.Collection(id); col != nil {
		t.Fatal("deleted collection still readable")
	}
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM collection_games`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("cascade left membership rows behind (%d, %v)", n, err)
	}
}

// TestSetSystemHiddenAll pins the bulk unhide: only actually-flipped rows
// count (the caller skips the regeneration trigger when nothing changed).
func TestSetSystemHiddenAll(t *testing.T) {
	s := seedP6Store(t) // C Hidden pre-hidden
	n, err := s.SetSystemHiddenAll("nes", false)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("unhide-all changed %d rows, want 1 (only the hidden one)", n)
	}
	n, err = s.SetSystemHiddenAll("nes", false)
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("re-unhide changed %d rows, want 0", n)
	}
	counts, err := s.HiddenCountsBySystem()
	if err != nil {
		t.Fatal(err)
	}
	if len(counts) != 0 {
		t.Fatalf("hidden counts after unhide-all = %v, want empty", counts)
	}
	if _, err := s.SetSystemHiddenAll("nes", true); err != nil {
		t.Fatal(err)
	}
	counts, _ = s.HiddenCountsBySystem()
	if counts["nes"] != 3 {
		t.Fatalf("hidden count = %d, want 3", counts["nes"])
	}
}

// TestCollectionShortnameRejectsCatalogueIdentities pins ADV-P7-01: a
// name whose derived shortname is a catalogue system key (or a system's
// "-pending" section shortname) is rejected at create AND rename with an
// error naming the collision — such a collection could never be emitted
// (the strict parser rejects duplicate shortnames in one file), so the
// old success-while-generation-refuses behavior is the bug.
func TestCollectionShortnameRejectsCatalogueIdentities(t *testing.T) {
	s := seedP6Store(t)
	// UpsertSystems REPLACES the table (absent keys are deleted), so the
	// second system rides along with nes — never instead of it.
	if err := s.UpsertSystems([]SystemRow{
		{Key: "nes", Collection: "Nintendo Entertainment System", Bucket: "cartridge", Core: "fceumm", SortOrder: 1, Extensions: `["nes"]`},
		{Key: "snes", Collection: "Super NES", Bucket: "cartridge", Core: "snes9x", SortOrder: 2, Extensions: `["sfc"]`},
	}); err != nil {
		t.Fatal(err)
	}

	collides := func(name string) *ReservedShortnameError {
		t.Helper()
		_, err := s.CreateCollection(name, "")
		var rerr *ReservedShortnameError
		if !errors.As(err, &rerr) {
			t.Fatalf("CreateCollection(%q) err = %v, want ReservedShortnameError", name, err)
		}
		return rerr
	}

	// Main-collection identity collision ("NES" → "nes").
	e := collides("NES")
	if e.Shortname != "nes" || e.SystemKey != "nes" || e.Pending {
		t.Fatalf("NES collision = %+v, want shortname/system nes non-pending", e)
	}
	// Derivation is lowercased — "SNES" must collide exactly the same way.
	if e := collides("SNES"); e.Shortname != "snes" || e.SystemKey != "snes" {
		t.Fatalf("SNES collision = %+v, want snes/snes", e)
	}
	// Pending-section collision ("NES Pending" → "nes-pending").
	e = collides("NES Pending")
	if !e.Pending || e.Shortname != "nes-pending" || e.SystemKey != "nes" {
		t.Fatalf("pending collision = %+v, want nes-pending via nes", e)
	}
	// The error text names the collision (the operator-facing bar).
	if msg := e.Error(); !strings.Contains(msg, "nes-pending") || !strings.Contains(msg, `"NES Pending"`) {
		t.Fatalf("collision error must name both sides, got %q", msg)
	}
	var n int
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM collections`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("rejected creates left %d rows behind (%v)", n, err)
	}

	// Non-colliding names still land with their derived identity.
	id, err := s.CreateCollection("Kitchen Quick-Play", "")
	if err != nil {
		t.Fatalf("non-colliding create rejected: %v", err)
	}
	col, _ := s.Collection(id)
	if col == nil || col.Shortname != "kitchen-quick-play" {
		t.Fatalf("non-colliding create wrong: %+v", col)
	}

	// Rename is probed symmetrically (ADV-P7-01): onto a catalogue
	// identity → rejected; onto a free name → allowed (self-healing for
	// pre-fix rows whose stored shortname already collided).
	if err := s.UpdateCollection(id, "Snes", ""); !errors.As(err, new(*ReservedShortnameError)) {
		t.Fatalf("rename to SNES = %v, want ReservedShortnameError", err)
	}
	if err := s.UpdateCollection(id, "Late Night Set", ""); err != nil {
		t.Fatalf("free rename rejected: %v", err)
	}
	col, _ = s.Collection(id)
	if col.Name != "Late Night Set" || col.Shortname != "kitchen-quick-play" {
		t.Fatalf("rename mangled the collection: %+v", col)
	}
}

// TestGameDeleteCascadesCollectionMembership pins ADV-P7-05: deleting a
// game row removes its memberships (collection_games.game_id ON DELETE
// CASCADE), via BOTH production paths — the scan-time prune that replaces
// a vanished file set, and a direct row deletion.
func TestGameDeleteCascadesCollectionMembership(t *testing.T) {
	s := seedP6Store(t)
	// A second system+game so each membership sits under a different
	// system key (the prune below must remove exactly ONE of them).
	// UpsertSystems replaces the table — nes rides along.
	if err := s.UpsertSystems([]SystemRow{
		{Key: "nes", Collection: "Nintendo Entertainment System", Bucket: "cartridge", Core: "fceumm", SortOrder: 1, Extensions: `["nes"]`},
		{Key: "snes", Collection: "Super NES", Bucket: "cartridge", Core: "snes9x", SortOrder: 2, Extensions: `["sfc"]`},
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.ReplaceSystemGames("snes", []GameRow{
		{RelPath: "D Snes Game (USA).sfc", SizeBytes: 4},
	}, time.Now()); err != nil {
		t.Fatal(err)
	}

	memberships := func() int {
		t.Helper()
		var n int
		if err := s.db.QueryRow(`SELECT COUNT(*) FROM collection_games`).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}

	id, err := s.CreateCollection("Cascade Probe", "")
	if err != nil {
		t.Fatal(err)
	}
	games, err := s.ListGames(GameListOpts{Limit: 10})
	if err != nil {
		t.Fatal(err)
	}
	var first, second GameSummary
	for _, g := range games.Games {
		switch g.RelPath {
		case "A First (USA).nes":
			first = g
		case "D Snes Game (USA).sfc":
			second = g
		}
	}
	if first.ID == 0 || second.ID == 0 {
		t.Fatal("fixture games missing")
	}
	if err := s.AddCollectionGame(id, first.SystemKey, first.ID); err != nil {
		t.Fatal(err)
	}
	if err := s.AddCollectionGame(id, second.SystemKey, second.ID); err != nil {
		t.Fatal(err)
	}
	if got := memberships(); got != 2 {
		t.Fatalf("memberships before cascade = %d, want 2", got)
	}

	// Path 1: the scan-time prune (game vanished from the tree).
	later := time.Now().Add(time.Minute)
	if err := s.ReplaceSystemGames(first.SystemKey, nil, later); err != nil {
		t.Fatal(err)
	}
	if got := memberships(); got != 1 {
		t.Fatalf("memberships after game prune = %d, want 1", got)
	}

	// Path 2: direct row deletion (same FK cascade).
	if _, err := s.db.Exec(`DELETE FROM games WHERE id=?`, second.ID); err != nil {
		t.Fatal(err)
	}
	if got := memberships(); got != 0 {
		t.Fatalf("memberships after game delete = %d, want 0 (cascade broken)", got)
	}
}

// TestMigrateV8DatabaseStepsToV9PreservesGames pins the P8 systems-table
// rebuild: with the production DSN's foreign_keys enforcement ON, a naive
// DROP TABLE would run its implicit DELETE with cascades and wipe every
// games row. After the rebuild: version 9, the catalogue row survives
// with source='catalogue', its game survives (the join still resolves),
// the widened bucket CHECK accepts 'exo', cascade cleanup still works,
// and the CHECK still rejects garbage buckets.
func TestMigrateV8DatabaseStepsToV9PreservesGames(t *testing.T) {
	p := filepath.Join(t.TempDir(), "v8.db")
	db, err := sql.Open("sqlite", "file:"+p+"?_pragma=foreign_keys(1)")
	if err != nil {
		t.Fatal(err)
	}
	var fk int
	if err := db.QueryRow(`PRAGMA foreign_keys`).Scan(&fk); err != nil || fk != 1 {
		t.Fatalf("test precondition: foreign_keys on = %d, %v", fk, err)
	}
	steps := []string{}
	for _, grp := range [][]string{schemaV1, schemaV2, schemaV3, schemaV4, schemaV5, schemaV6, schemaV7, schemaV8} {
		steps = append(steps, grp...)
	}
	for _, stmt := range steps {
		if _, err := db.Exec(stmt); err != nil && !strings.Contains(err.Error(), "already exists") {
			t.Fatalf("seed v8 schema: %v", err)
		}
	}
	if _, err := db.Exec(`INSERT INTO systems (key, collection, bucket, sort_order) VALUES ('nes', 'NES', 'cartridge', 1)`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`INSERT INTO games (system_key, rel_path, size_bytes, first_seen_at, last_seen_at)
		VALUES ('nes', 'Starlit Vault (USA).nes', 5, '2026-08-20T00:00:00Z', '2026-08-20T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`PRAGMA user_version = 8`); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	s, err := Open(p)
	if err != nil {
		t.Fatalf("Open v8 database: %v", err)
	}
	defer s.Close() //nolint:errcheck // test
	if got := s.SchemaVersion(); got != SchemaVersion {
		t.Fatalf("migrated user_version = %d, want %d", got, SchemaVersion)
	}

	// The catalogue system survived, reads as catalogue-sourced...
	sys, err := s.System("nes")
	if err != nil || sys == nil {
		t.Fatalf("System(nes) after v9 = %+v, %v; want present", sys, err)
	}
	if sys.Source != SourceCatalogue {
		t.Fatalf("source = %q, want %q", sys.Source, SourceCatalogue)
	}
	// ...and its GAME survived the rebuild (the cascade-wipe regression).
	game, err := s.GetGame("nes", 1)
	if err != nil || game == nil || game.RelPath != "Starlit Vault (USA).nes" {
		t.Fatalf("game lost by the v9 rebuild: %+v, %v", game, err)
	}

	// The widened bucket accepts exo rows; enforcement is back ON, so
	// cascade cleanup works and garbage buckets still bounce.
	if err := s.UpsertExoSystem(SystemRow{Key: "dos", Collection: "eXoDOS", Bucket: ExoBucket, SortOrder: 1000}); err != nil {
		t.Fatalf("exo bucket rejected: %v", err)
	}
	if _, err := s.db.Exec(`INSERT INTO systems (key, collection, bucket, sort_order) VALUES ('x', 'X', 'floptical', 99)`); err == nil {
		t.Fatal("garbage bucket accepted — CHECK constraint gone")
	}
	if _, err := s.db.Exec(`DELETE FROM systems WHERE key='nes'`); err != nil {
		t.Fatal(err)
	}
	if g, _ := s.GetGame("nes", 1); g != nil {
		t.Fatal("cascade cleanup broken after the rebuild (game outlived its system)")
	}
	s2, err := s.db.Exec(`PRAGMA foreign_keys`)
	_ = s2 // (read directly below instead)
	var on int
	if err := s.db.QueryRow(`PRAGMA foreign_keys`).Scan(&on); err != nil || on != 1 {
		t.Fatalf("foreign_keys left OFF after migration: on=%d err=%v", on, err)
	}
}

// TestUpsertSystemsPruneKeepsExoRows: a catalogue rescan must never prune
// (and thereby cascade-away) eXo-imported systems — P8's load-bearing
// UpsertSystems contract.
func TestUpsertSystemsPruneKeepsExoRows(t *testing.T) {
	s := openTemp(t)
	defer s.Close() //nolint:errcheck // test

	catalogue := []SystemRow{
		{Key: "nes", Collection: "NES", Bucket: "cartridge", SortOrder: 1},
		{Key: "snes", Collection: "SNES", Bucket: "cartridge", SortOrder: 2},
	}
	if err := s.UpsertSystems(catalogue); err != nil {
		t.Fatal(err)
	}
	if err := s.UpsertExoSystem(SystemRow{Key: "dos", Collection: "eXoDOS", Bucket: ExoBucket, SortOrder: 1000}); err != nil {
		t.Fatal(err)
	}

	// A rescan whose TSV no longer lists snes prunes snes only.
	if err := s.UpsertSystems([]SystemRow{catalogue[0]}); err != nil {
		t.Fatal(err)
	}
	systems, err := s.Systems()
	if err != nil {
		t.Fatal(err)
	}
	keys := map[string]bool{}
	for _, sys := range systems {
		keys[sys.Key] = true
	}
	if !keys["nes"] || keys["snes"] || !keys["dos"] {
		t.Fatalf("rescan prune wrong: %v (want nes kept, snes pruned, dos untouched)", keys)
	}
}

// TestSetSystemCoverFlagsAndExoStats: full-replace cover flags + the P8
// per-collection aggregates the inventory endpoint renders from.
func TestSetSystemCoverFlagsAndExoStats(t *testing.T) {
	s := openTemp(t)
	defer s.Close() //nolint:errcheck // test

	if err := s.UpsertExoSystem(SystemRow{Key: "dos", Collection: "eXoDOS", Bucket: ExoBucket, SortOrder: 1000}); err != nil {
		t.Fatal(err)
	}
	games := []GameRow{{RelPath: "a.conf"}, {RelPath: "b.conf"}, {RelPath: "c.conf"}}
	if err := s.ReplaceSystemGames("dos", games, time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := s.SetSystemCoverFlags("dos", []string{"a.conf", "c.conf"}); err != nil {
		t.Fatal(err)
	}
	stats, err := s.ExoStatsBySystem()
	if err != nil {
		t.Fatal(err)
	}
	if got := stats["dos"]; got.Games != 3 || got.Art != 2 {
		t.Fatalf("exo stats = %+v, want {3 2}", got)
	}

	// Re-import that lost art clears stale flags (full-replace).
	if err := s.SetSystemCoverFlags("dos", []string{"c.conf"}); err != nil {
		t.Fatal(err)
	}
	stats, _ = s.ExoStatsBySystem()
	if got := stats["dos"]; got.Art != 1 {
		t.Fatalf("stale cover flag survived replace: %+v", got)
	}
}
