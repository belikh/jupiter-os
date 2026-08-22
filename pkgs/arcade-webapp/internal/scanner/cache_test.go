package scanner

import (
	"archive/zip"
	"bytes"
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// writeCacheDB materializes a db.xml fixture (same shape europa's caches
// have — verified against the committed scanner fixtures).
func writeCacheDB(t *testing.T, dir, xmlText string) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "db.xml")
	if err := os.WriteFile(path, []byte(xmlText), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestReadCacheCoverage(t *testing.T) {
	dir := t.TempDir()
	writeCacheDB(t, dir, `<?xml version="1.0" encoding="UTF-8"?>
<db>
  <resource id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" type="description" source="ScreenScraper" timestamp="1">Desc A</resource>
  <resource id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" type="cover" source="ScreenScraper" timestamp="1">covers/a.png</resource>
  <resource id="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" type="description" source="ScreenScraper" timestamp="1">Desc B</resource>
  <resource id="cccccccccccccccccccccccccccccccccccccccc" type="description" source="thegamesdb" timestamp="1">Desc C</resource>
  <resource id="dddddddddddddddddddddddddddddddddddddddd" type="wheel" source="ScreenScraper">wheels/d.png</resource>
</db>
`)
	cc, err := ReadCacheCoverage(dir)
	if err != nil {
		t.Fatal(err)
	}
	// 4 distinct ids; 3 with descriptions; 1 with a cover; the wheel-type
	// resource counts toward Entries only.
	if cc.Entries != 4 || cc.Descriptions != 3 || cc.Covers != 1 {
		t.Errorf("coverage = %d/%d/%d, want 4/3/1", cc.Entries, cc.Descriptions, cc.Covers)
	}
	if len(cc.DescIDs) != 3 || len(cc.CoverIDs) != 1 {
		t.Errorf("id sets = %d desc / %d cover, want 3/1", len(cc.DescIDs), len(cc.CoverIDs))
	}

	// Absent cache reads as zero-value, NOT an error (unscraped platform).
	empty, err := ReadCacheCoverage(filepath.Join(t.TempDir(), "nope"))
	if err != nil {
		t.Fatalf("absent cache: %v", err)
	}
	if empty.Entries != 0 || len(empty.DescIDs) != 0 {
		t.Errorf("absent cache = %+v, want zero coverage", empty)
	}

	// Corrupt db.xml is an error (the scan records it as a warning).
	bad := t.TempDir()
	writeCacheDB(t, bad, "<db><resource")
	if _, err := ReadCacheCoverage(bad); err == nil {
		t.Error("corrupt db.xml must error")
	}
}

// TestCountCacheGamesUnchanged pins that the P5 refactor kept the scan
// heuristic identical (distinct ids, absent dir = 0).
func TestCountCacheGamesUnchanged(t *testing.T) {
	dir := t.TempDir()
	writeCacheDB(t, dir, `<db>
  <resource id="x1" type="description">1</resource>
  <resource id="x2" type="description">2</resource>
  <resource id="x1" type="cover">1</resource>
</db>`)
	n, err := countCacheGames(dir)
	if err != nil || n != 2 {
		t.Errorf("countCacheGames = %d, %v; want 2, nil", n, err)
	}
	if n, err := countCacheGames(filepath.Join(dir, "missing")); err != nil || n != 0 {
		t.Errorf("absent dir = %d, %v; want 0, nil", n, err)
	}
}

func TestCacheID(t *testing.T) {
	dir := t.TempDir()

	// Raw file: lowercase hex SHA1 of contents.
	p := filepath.Join(dir, "Game (USA).nes")
	if err := os.WriteFile(p, []byte("abc"), 0o644); err != nil {
		t.Fatal(err)
	}
	sum := sha1.Sum([]byte("abc"))
	want := hex.EncodeToString(sum[:])
	got, err := CacheID(p)
	if err != nil || got != want {
		t.Errorf("CacheID raw = %s, %v; want %s", got, err, want)
	}

	// Zip: SHA1 of the FIRST regular entry's decompressed contents
	// (directory entries are skipped).
	zp := filepath.Join(dir, "Set.zip")
	zf, err := os.Create(zp)
	if err != nil {
		t.Fatal(err)
	}
	zw := zip.NewWriter(zf)
	w1, err := zw.Create("dir/")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = w1.Write(nil)
	w2, err := zw.Create("Inner (USA).nes")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w2.Write([]byte("abc")); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := zf.Close(); err != nil {
		t.Fatal(err)
	}
	got, err = CacheID(zp)
	if err != nil || got != want {
		t.Errorf("CacheID zip = %s, %v; want inner sha1 %s", got, err, want)
	}

	// Oversized files refuse to hash (ErrROMTooLarge), false-negative-safe.
	old := romHashSizeLimit
	romHashSizeLimit = 2
	defer func() { romHashSizeLimit = old }()
	if _, err := CacheID(p); !errors.Is(err, ErrROMTooLarge) {
		t.Errorf("oversized CacheID err = %v, want ErrROMTooLarge", err)
	}
}

// TestApplyCacheFlags: the end-to-end best-effort mapping — a real ROM
// whose sha1 is keyed in db.xml gets its flags set and scrape_coverage
// refreshed; a cache wipe clears every flag (full-replace semantics).
func TestApplyCacheFlags(t *testing.T) {
	root := t.TempDir()
	st, err := store.Open(filepath.Join(root, "arcade.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close() //nolint:errcheck // test
	sys := store.SystemRow{Key: "nes", Collection: "NES", Bucket: "cartridge",
		SortOrder: 1, Extensions: `["nes"]`}
	if err := st.UpsertSystems([]store.SystemRow{sys}); err != nil {
		t.Fatal(err)
	}

	sysDir := filepath.Join(root, "games", "nes")
	if err := os.MkdirAll(sysDir, 0o755); err != nil {
		t.Fatal(err)
	}
	romBody := bytes.Repeat([]byte("rom-bytes"), 8)
	if err := os.WriteFile(filepath.Join(sysDir, "A (USA).nes"), romBody, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := st.ReplaceSystemGames("nes", []store.GameRow{
		{RelPath: "A (USA).nes", SizeBytes: int64(len(romBody))},
	}, time.Now()); err != nil {
		t.Fatal(err)
	}

	id := sha1Hex(t, romBody)
	cacheDir := CacheDirFor(filepath.Join(root, "cache"), sys)
	writeCacheDB(t, cacheDir, `<db>
  <resource id="`+id+`" type="description">text</resource>
  <resource id="`+id+`" type="cover">covers/x.png</resource>
  <resource id="other000000000000000000000000000000000000000" type="description">text</resource>
</db>`)

	if err := ApplyCacheFlags(st, sys, sysDir, cacheDir); err != nil {
		t.Fatalf("ApplyCacheFlags: %v", err)
	}
	page, err := st.ListGames(store.GameListOpts{SystemKey: "nes"})
	if err != nil {
		t.Fatal(err)
	}
	d, err := st.GetGame("nes", page.Games[0].ID)
	if err != nil || d == nil {
		t.Fatalf("GetGame: %v, %v", d, err)
	}
	if !d.HasDescription || !d.HasCover {
		t.Errorf("flags = desc:%v cover:%v, want both true", d.HasDescription, d.HasCover)
	}
	rows, err := st.SystemSummary()
	if err != nil {
		t.Fatal(err)
	}
	if rows[0].CacheEntries != 2 {
		t.Errorf("scrape_coverage entries = %d, want 2 (distinct ids)", rows[0].CacheEntries)
	}

	// Wiped cache → full-replace clears every flag.
	if err := os.Remove(filepath.Join(cacheDir, "db.xml")); err != nil {
		t.Fatal(err)
	}
	if err := ApplyCacheFlags(st, sys, sysDir, cacheDir); err != nil {
		t.Fatalf("ApplyCacheFlags after wipe: %v", err)
	}
	d, _ = st.GetGame("nes", page.Games[0].ID)
	if d.HasDescription || d.HasCover {
		t.Errorf("flags after wipe = %+v, want both false", d)
	}
	if rows, _ = st.SystemSummary(); rows[0].CacheEntries != 0 {
		t.Errorf("entries after wipe = %d, want 0", rows[0].CacheEntries)
	}
}

// TestApplyCacheFlagsSkipsOversized: a game above the hash limit stays
// unflagged while its sibling still maps — one bad file must not fail
// the pass nor block the others.
func TestApplyCacheFlagsSkipsOversized(t *testing.T) {
	root := t.TempDir()
	st, err := store.Open(filepath.Join(root, "arcade.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close() //nolint:errcheck // test
	sys := store.SystemRow{Key: "nes", Collection: "NES", Bucket: "cartridge",
		SortOrder: 1, Extensions: `["nes"]`}
	if err := st.UpsertSystems([]store.SystemRow{sys}); err != nil {
		t.Fatal(err)
	}
	sysDir := filepath.Join(root, "games", "nes")
	if err := os.MkdirAll(sysDir, 0o755); err != nil {
		t.Fatal(err)
	}
	smallBody := []byte("small") // 5 bytes
	hugeBody := []byte("huge")   // 4 bytes
	if err := os.WriteFile(filepath.Join(sysDir, "Small.nes"), smallBody, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sysDir, "Huge.nes"), hugeBody, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := st.ReplaceSystemGames("nes", []store.GameRow{
		{RelPath: "Small.nes", SizeBytes: int64(len(smallBody))},
		{RelPath: "Huge.nes", SizeBytes: int64(len(hugeBody))},
	}, time.Now()); err != nil {
		t.Fatal(err)
	}

	cacheDir := CacheDirFor(filepath.Join(root, "cache"), sys)
	writeCacheDB(t, cacheDir, `<db>
  <resource id="`+sha1Hex(t, hugeBody)+`" type="description">t</resource>
</db>`)

	old := romHashSizeLimit
	romHashSizeLimit = 4 // Huge.nes (4B) hashes; Small.nes (5B) exceeds
	defer func() { romHashSizeLimit = old }()

	if err := ApplyCacheFlags(st, sys, sysDir, cacheDir); err != nil {
		t.Fatalf("ApplyCacheFlags: %v", err)
	}
	page, _ := st.ListGames(store.GameListOpts{SystemKey: "nes"})
	byRel := map[string]int64{}
	for _, g := range page.Games {
		byRel[g.RelPath] = g.ID
	}
	dSmall, err := st.GetGame("nes", byRel["Small.nes"])
	if err != nil || dSmall == nil {
		t.Fatalf("GetGame Small: %v, %v", dSmall, err)
	}
	dHuge, _ := st.GetGame("nes", byRel["Huge.nes"])
	if dSmall.HasDescription || dSmall.HasCover {
		t.Error("oversized Small.nes must stay unflagged")
	}
	if dHuge == nil || !dHuge.HasDescription {
		t.Error("Huge.nes should be description-flagged")
	}
}

func sha1Hex(t *testing.T, b []byte) string {
	t.Helper()
	sum := sha1.Sum(b)
	return hex.EncodeToString(sum[:])
}
