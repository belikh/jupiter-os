package scanner

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/fixture"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// buildFixtureTree materializes the deterministic fixture corpus in the
// shape the production retro tree has on europa:
//
//	root/games/cartridge/<sys>/<rom>          (fixturegen output)
//	root/metadata/no-intro-dats/<sys>.dat     (committed DATs)
//	root/metadata/skyscraper-cache/<sys>/db.xml (synthetic caches)
//	root/cache/incoming/<sys>/...              (staged downloads)
//	root/cartridge-catalogue.tsv              (3-row subset of the fleet TSV)
func buildFixtureTree(t *testing.T) (root, dbPath string) {
	t.Helper()
	root = t.TempDir()
	dbPath = filepath.Join(t.TempDir(), "arcade.db")

	if err := fixture.WriteROMs(filepath.Join(root, "games", "cartridge")); err != nil {
		t.Fatal(err)
	}
	if err := fixture.WriteDATs(filepath.Join(root, "metadata", "no-intro-dats")); err != nil {
		t.Fatal(err)
	}

	// Synthetic Skyscraper caches: nes covers 3 of 5 games, snes all 4,
	// gb none (absent db.xml).
	nesCache := filepath.Join(root, "metadata", "skyscraper-cache", "nes")
	if err := os.MkdirAll(nesCache, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(nesCache, "db.xml"), []byte(`<?xml version="1.0" encoding="UTF-8"?>
<db>
  <resource id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" type="description" source="ScreenScraper" timestamp="1">Desc A</resource>
  <resource id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" type="cover" source="ScreenScraper" timestamp="1">covers/a.png</resource>
  <resource id="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" type="description" source="ScreenScraper" timestamp="1">Desc B</resource>
  <resource id="cccccccccccccccccccccccccccccccccccccccc" type="description" source="thegamesdb" timestamp="1">Desc C</resource>
</db>
`), 0o644); err != nil {
		t.Fatal(err)
	}
	snesCache := filepath.Join(root, "metadata", "skyscraper-cache", "snes")
	if err := os.MkdirAll(snesCache, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(snesCache, "db.xml"), []byte(`<db>
  <resource id="d1" type="description" source="x">1</resource>
  <resource id="d2" type="description" source="x">2</resource>
  <resource id="d3" type="description" source="x">3</resource>
  <resource id="d4" type="description" source="x">4</resource>
</db>
`), 0o644); err != nil {
		t.Fatal(err)
	}

	// Incoming staging: one partial nes download + a stray control file.
	inc := filepath.Join(root, "cache", "incoming", "nes")
	if err := os.MkdirAll(inc, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(inc, "Partial (USA).nes"), make([]byte, 128), 0o644); err != nil {
		t.Fatal(err)
	}

	// A 3-row catalogue subset shaped exactly like the fleet TSV.
	tsv := "nes\tNintendo Entertainment System\tfceumm\t-\tnes\t-\tcartridge\tT.torrent\n" +
		"snes\tSuper Nintendo Entertainment System\tsnes9x\t-\tsfc,smc\t-\tcartridge\tT2.torrent\n" +
		"gb\tNintendo Game Boy\tgambatte\t-\tgb\t-\tcartridge\t-\n"
	if err := os.WriteFile(filepath.Join(root, "cartridge-catalogue.tsv"), []byte(tsv), 0o644); err != nil {
		t.Fatal(err)
	}
	return root, dbPath
}

func testConfig(root, dbPath string) Config {
	return Config{
		CatalogueTsv:       filepath.Join(root, "cartridge-catalogue.tsv"),
		CartridgeRoot:      filepath.Join(root, "games", "cartridge"),
		OpticalRoot:        filepath.Join(root, "games", "optical"),
		ModernRoot:         filepath.Join(root, "games", "modern"),
		DATDir:             filepath.Join(root, "metadata", "no-intro-dats"),
		SkyscraperCacheDir: filepath.Join(root, "metadata", "skyscraper-cache"),
		IncomingDir:        filepath.Join(root, "cache", "incoming"),
		InventoryFile:      filepath.Join(root, "state", "inventory.json"), // absent: tolerated
		DBPath:             dbPath,
	}
}

func TestScanFixtureTree(t *testing.T) {
	root, dbPath := buildFixtureTree(t)
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close() //nolint:errcheck // test

	sc := New(testConfig(root, dbPath), st)
	res, err := sc.Scan()
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}

	if res.Systems != 3 || res.Errors != 0 {
		t.Errorf("Scan result = %+v, want 3 systems 0 errors", res)
	}

	sumry, err := st.SystemSummary()
	if err != nil {
		t.Fatal(err)
	}
	byKey := map[string]store.SystemSummary{}
	for _, r := range sumry {
		byKey[r.Key] = r
	}

	// ROM counts + sizes against the fixture corpus.
	var wantBytes int64
	for _, g := range fixture.Systems()[0].Games { // nes
		wantBytes += int64(g.Size)
	}
	nes := byKey["nes"]
	if nes.GameCount != 5 || nes.TotalBytes != wantBytes {
		t.Errorf("nes = %d games / %d bytes, want 5 / %d", nes.GameCount, nes.TotalBytes, wantBytes)
	}
	if byKey["snes"].GameCount != 4 || byKey["gb"].GameCount != 4 {
		t.Errorf("snes/gb counts = %d/%d, want 4/4", byKey["snes"].GameCount, byKey["gb"].GameCount)
	}

	// DAT currency: the fixture DATs carry date 2026-08-21, version 1.0,
	// and one <game> per fixture game.
	if nes.DATDate != "2026-08-21" || nes.DATVersion != "1.0" || nes.DATRomCount != 5 {
		t.Errorf("nes DAT = %q/%q/%d, want 2026-08-21/1.0/5", nes.DATDate, nes.DATVersion, nes.DATRomCount)
	}

	// Coverage heuristic: distinct resource ids vs ROM count.
	if nes.CacheEntries != 3 || nes.CoveragePct() != 60 {
		t.Errorf("nes cache = %d entries (%d%%), want 3 (60%%)", nes.CacheEntries, nes.CoveragePct())
	}
	if snes := byKey["snes"]; snes.CacheEntries != 4 || snes.CoveragePct() != 100 {
		t.Errorf("snes cache = %d (%d%%), want 4 (100%%)", snes.CacheEntries, snes.CoveragePct())
	}
	if gb := byKey["gb"]; gb.CacheEntries != 0 || gb.CoveragePct() != 0 {
		t.Errorf("gb cache = %d (%d%%), want 0 (0%%)", gb.CacheEntries, gb.CoveragePct())
	}

	// Incoming summary.
	if res.IncomingFiles != 1 || res.IncomingBytes != 128 {
		t.Errorf("incoming = %d files / %d bytes, want 1/128", res.IncomingFiles, res.IncomingBytes)
	}

	// Inventory file was absent — tolerated, table empty, run still ok.
	last, err := st.LastRun()
	if err != nil || last == nil || last.Status != "ok" {
		t.Fatalf("last run = %+v, %v; want ok", last, err)
	}

	// Scan is idempotent: a second scan yields the same counts.
	if _, err := sc.Scan(); err != nil {
		t.Fatalf("Scan 2: %v", err)
	}
	sumry2, err := st.SystemSummary()
	if err != nil {
		t.Fatal(err)
	}
	if len(sumry2) != len(sumry) {
		t.Fatalf("systems after rescan = %d, want %d", len(sumry2), len(sumry))
	}
}

func TestScanImportsLegacyInventory(t *testing.T) {
	root, dbPath := buildFixtureTree(t)
	invDir := filepath.Join(root, "state")
	if err := os.MkdirAll(invDir, 0o755); err != nil {
		t.Fatal(err)
	}
	doc := map[string]any{
		"generated_at": "2026-08-20T10:00:00Z",
		"cartridge": map[string]any{
			"nes":  map[string]any{"count": 5, "size_bytes": 294},
			"snes": map[string]any{"count": 4, "size_bytes": 100},
		},
		"optical": map[string]any{},
		"modern":  map[string]any{},
		"exo":     map[string]any{},
		"rom_acquire": map[string]any{
			"unit": "jupiter-rom-acquire.service", "active_state": "inactive",
		},
	}
	b, _ := json.Marshal(doc)
	if err := os.WriteFile(filepath.Join(invDir, "inventory.json"), b, 0o644); err != nil {
		t.Fatal(err)
	}

	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close() //nolint:errcheck // test

	if _, err := New(testConfig(root, dbPath), st).Scan(); err != nil {
		t.Fatal(err)
	}
	rows, err := st.InventoryRows()
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 {
		t.Fatalf("inventory rows = %d, want 2 (nes+snes)", len(rows))
	}
	if rows[0].SystemKey != "nes" || rows[0].Count != 5 || rows[0].SizeBytes != 294 {
		t.Errorf("inventory nes row = %+v", rows[0])
	}
	if rows[0].GeneratedAt != "2026-08-20T10:00:00Z" {
		t.Errorf("inventory generated_at = %q", rows[0].GeneratedAt)
	}
}

func TestScanSerializedWhileRunning(t *testing.T) {
	root, dbPath := buildFixtureTree(t)
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close() //nolint:errcheck // test
	sc := New(testConfig(root, dbPath), st)

	sc.state.Running = true // simulate an in-flight scan
	if _, err := sc.Scan(); err == nil {
		t.Fatal("Scan while running succeeded, want ErrBusy")
	}
	if !sc.State().Running {
		t.Error("State().Running = false, want true")
	}
}

func TestDATHeaderParse(t *testing.T) {
	// Committed fixture DAT: header date/version + game count.
	info, err := readDAT(filepath.Join("..", "..", "testdata", "dats", "gb.dat"))
	if err != nil {
		t.Fatal(err)
	}
	if info.DatName == "" || info.Version != "1.0" || info.Date != "2026-08-21" {
		t.Errorf("gb.dat header = %+v", info)
	}
	if info.RomCount != 4 {
		t.Errorf("gb.dat rom count = %d, want 4", info.RomCount)
	}
}

// ADV-P1-02: real Fresh1G1R McLean 1G1R DATs carry
// <date>2026-06-22 07-44-23</date> (space separator, dash time). The
// header must parse and AgeDays must turn it into days — otherwise every
// live card shows a "?" age chip and the staleness aggregate can never
// fire.
func TestDATHeaderParseMcLeanShape(t *testing.T) {
	info, err := readDAT(filepath.Join("..", "..", "testdata", "dats", "mclean-shape.dat"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Date != "2026-06-22 07-44-23" {
		t.Errorf("mclean-shape.dat date = %q, want the raw McLean-shaped string", info.Date)
	}
	if info.Version != "20260622-074423" || info.RomCount != 2 {
		t.Errorf("mclean-shape.dat version/roms = %q/%d", info.Version, info.RomCount)
	}
	now := time.Date(2026, 8, 21, 0, 0, 0, 0, time.UTC)
	if got := AgeDays(info.Date, now); got != 59 {
		t.Errorf("AgeDays(%q) = %d, want 59 (2026-06-22 07:44:23 → 2026-08-21 00:00 = 59.67d, truncated)", info.Date, got)
	}
}

func TestParseSkyHandleRouting(t *testing.T) {
	// ps1's cache lives under the skyHandle dir (psx), not the system key.
	dir := t.TempDir()
	cacheDir := filepath.Join(dir, "psx")
	if err := os.MkdirAll(cacheDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cacheDir, "db.xml"),
		[]byte(`<db><resource id="x" type="description" source="s">d</resource></db>`), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := countCacheGames(cacheDir)
	if err != nil {
		t.Fatal(err)
	}
	if got != 1 {
		t.Errorf("countCacheGames = %d, want 1", got)
	}
	if _, err := countCacheGames(filepath.Join(dir, "nope")); err != nil {
		t.Errorf("countCacheGames on absent dir = error %v, want 0,nil", err)
	}
}

func TestAgeDays(t *testing.T) {
	now := time.Date(2026, 8, 21, 0, 0, 0, 0, time.UTC)
	cases := map[string]int{
		"2026-08-21": 0,
		"2026-08-14": 7,
		"2026-01-01": 232,
		"":           -1,
		"garbage":    -1,
		// ADV-P1-02: the Fresh1G1R McLean family — space separator,
		// dash time — plus the colon variant, defensively. 59, not 60:
		// the 07:44:23 build time makes the elapsed 59.67d at midnight,
		// and AgeDays truncates (same semantics as the plain-date cases).
		"2026-06-22 07-44-23": 59,
		"2026-06-22 07:44:23": 59,
	}
	for date, want := range cases {
		if got := AgeDays(date, now); got != want {
			t.Errorf("AgeDays(%q) = %d, want %d", date, got, want)
		}
	}
}

// ADV-P1-03: a rescan while a bucket is unreadable (unmounted pool,
// permission shift) must NOT prune the affected systems' games rows —
// replacing with a partial/empty walk would silently wipe the
// hidden/verify_state/first_seen the schema promises rescans preserve.
func TestScanKeepsRowsWhenDirUnreadable(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("chmod 000 does not block reads for root; run as a normal user")
	}
	root, dbPath := buildFixtureTree(t)
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close() //nolint:errcheck // test

	sc := New(testConfig(root, dbPath), st)
	if _, err := sc.Scan(); err != nil {
		t.Fatal(err)
	}
	nesDir := filepath.Join(root, "games", "cartridge", "nes")
	rowsBefore := gameCount(t, st, "nes")
	if rowsBefore != 5 {
		t.Fatalf("nes rows after first scan = %d, want 5", rowsBefore)
	}

	// Make the nes dir unreadable (EACCES on ReadDir), rescan. The sleep
	// crosses an RFC3339-second boundary: ReplaceSystemGames prunes by
	// last_seen_at < ts, so a same-second rescan would hide the prune the
	// test exists to catch.
	if err := os.Chmod(nesDir, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(nesDir, 0o755) })
	time.Sleep(1100 * time.Millisecond)

	res, err := sc.Scan()
	if err != nil {
		t.Fatalf("second Scan returned error %v (warnings, not failures)", err)
	}
	if got := gameCount(t, st, "nes"); got != rowsBefore {
		t.Errorf("nes rows after unreadable rescan = %d, want %d (rows must survive)", got, rowsBefore)
	}
	// The failure must be visible: a warning naming the system.
	warned := false
	for _, w := range res.Warnings {
		if strings.Contains(w, "nes") && strings.Contains(w, "ROM walk") {
			warned = true
		}
	}
	if !warned {
		t.Errorf("no 'nes: ROM walk' warning among %v", res.Warnings)
	}
	// Other systems still refresh normally.
	if got := gameCount(t, st, "snes"); got != 4 {
		t.Errorf("snes rows = %d, want 4 (unrelated system must still scan)", got)
	}
}

func gameCount(t *testing.T, st *store.Store, system string) int64 {
	t.Helper()
	for _, s := range mustSummary(t, st) {
		if s.Key == system {
			return s.GameCount
		}
	}
	t.Fatalf("system %q missing from summary", system)
	return -1
}

func mustSummary(t *testing.T, st *store.Store) []store.SystemSummary {
	t.Helper()
	rows, err := st.SystemSummary()
	if err != nil {
		t.Fatal(err)
	}
	return rows
}
