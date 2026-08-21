package store

import (
	"path/filepath"
	"testing"
	"time"
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
	if got := s1.SchemaVersion(); got != 1 {
		t.Errorf("SchemaVersion = %d, want 1", got)
	}
	if err := s1.Close(); err != nil {
		t.Fatalf("close 1: %v", err)
	}

	s2, err := Open(p)
	if err != nil {
		t.Fatalf("open 2 (existing file): %v", err)
	}
	defer s2.Close() //nolint:errcheck // test
	if got := s2.SchemaVersion(); got != 1 {
		t.Errorf("SchemaVersion after reopen = %d, want 1", got)
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
