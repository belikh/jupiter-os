package store

import (
	"database/sql"
	"path/filepath"
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
		DatGames: 5, Found: 5, Missing: 0, Unmatched: 0, PromotedBytes: 4096,
		ReportPath: "/scratch/reports/nes.csv",
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
