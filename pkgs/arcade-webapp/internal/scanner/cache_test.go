package scanner

import (
	"archive/zip"
	"bytes"
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
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

// TestCacheDirForKeysOnCatalogueKey pins the ADV-P5-01 semantics: the
// cache dir is <cacheRoot>/<sys.Key> even when a SkyHandle differs (the
// handle is only the -p value), so the live europa caches under catalogue
// keys are found — and new3ds/3ds, which share SkyHandle "3ds", get
// distinct dirs instead of colliding on one shared cache.
func TestCacheDirForKeysOnCatalogueKey(t *testing.T) {
	root := filepath.Join(t.TempDir(), "cache")
	new3ds := CacheDirFor(root, store.SystemRow{Key: "new3ds", SkyHandle: "3ds"})
	threeDS := CacheDirFor(root, store.SystemRow{Key: "3ds", SkyHandle: "3ds"})
	if want := filepath.Join(root, "new3ds"); new3ds != want {
		t.Errorf("new3ds cache dir = %s, want %s (catalogue key, not the shared %q handle)", new3ds, want, "3ds")
	}
	if want := filepath.Join(root, "3ds"); threeDS != want {
		t.Errorf("3ds cache dir = %s, want %s", threeDS, want)
	}
	if new3ds == threeDS {
		t.Error("3ds and new3ds collide on one cache dir; handles must not key caches")
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

// ---- P6 carry-in: scan persists per-game sha1 ------------------------------

// TestScanPersistsSHA1 pins the P6 carry-in: a scan fills games.sha1 from
// CacheID for rows that lack one (best-effort), oversized files stay NULL
// (the ApplyCacheFlags cap), and the fill is ONCE — a later scan must not
// re-hash (or overwrite) an already-known row even if its bytes changed
// (sha1 is a display fact, verify ingest is the authority).
func TestScanPersistsSHA1(t *testing.T) {
	root := t.TempDir()
	st, err := store.Open(filepath.Join(root, "arcade.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close() //nolint:errcheck // test

	tsv := filepath.Join(root, "cat.tsv")
	if err := os.WriteFile(tsv, []byte("nes\tNES\tfceumm\t-\tnes\t-\tcartridge\t-\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	sysDir := filepath.Join(root, "games", "nes")
	if err := os.MkdirAll(sysDir, 0o755); err != nil {
		t.Fatal(err)
	}
	romBody := bytes.Repeat([]byte("first"), 16)
	if err := os.WriteFile(filepath.Join(sysDir, "A (USA).nes"), romBody, 0o644); err != nil {
		t.Fatal(err)
	}

	cfg := Config{
		CatalogueTsv:  tsv,
		CartridgeRoot: filepath.Join(root, "games"),
		DBPath:        "unused",
	}
	s := New(cfg, st)
	if _, err := s.Scan(); err != nil {
		t.Fatalf("scan 1: %v", err)
	}
	d, err := st.GetGame("nes", 1)
	if err != nil || d == nil {
		t.Fatalf("get game: %v/%v", d, err)
	}
	want := sha1Hex(t, romBody)
	if d.SHA1 != want {
		t.Fatalf("scan did not persist sha1: got %q want %q", d.SHA1, want)
	}

	// Oversized rows stay NULL (cap shrunk below the file size for the test).
	old := romHashSizeLimit
	romHashSizeLimit = 1024
	defer func() { romHashSizeLimit = old }()
	if err := os.WriteFile(filepath.Join(sysDir, "Huge (USA).nes"), bytes.Repeat([]byte("h"), 4096), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Scan(); err != nil {
		t.Fatalf("scan 2: %v", err)
	}
	page, err := st.ListGames(store.GameListOpts{SystemKey: "nes"})
	if err != nil {
		t.Fatal(err)
	}
	for _, g := range page.Games {
		if g.RelPath == "Huge (USA).nes" {
			d2, _ := st.GetGame("nes", g.ID)
			if d2.SHA1 != "" {
				t.Fatalf("oversized file got sha1 %q, want empty", d2.SHA1)
			}
		}
	}

	// Fill-once: changed content under the same path keeps the recorded id.
	romHashSizeLimit = old
	if err := os.WriteFile(filepath.Join(sysDir, "A (USA).nes"), bytes.Repeat([]byte("second"), 16), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Scan(); err != nil {
		t.Fatalf("scan 3: %v", err)
	}
	d, _ = st.GetGame("nes", 1)
	if d.SHA1 != want {
		t.Fatalf("fill-once violated: sha1 moved from %q to %q on re-scan", want, d.SHA1)
	}
}

// TestApplyCacheEnrichmentIngestsText pins the P7 carry-in: description
// TEXT from the platform cache lands in games.description (verbatim,
// keyed by CacheID), only for games the cache actually describes, and a
// later id-less pass never wipes what was stored.
func TestApplyCacheEnrichmentIngestsText(t *testing.T) {
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
	starlit := bytes.Repeat([]byte("vault-bytes"), 8)
	mecha := bytes.Repeat([]byte("garden-bytes"), 8)
	if err := os.WriteFile(filepath.Join(sysDir, "Starlit Vault (USA).nes"), starlit, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sysDir, "Mecha Garden (Japan).nes"), mecha, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := st.ReplaceSystemGames("nes", []store.GameRow{
		{RelPath: "Starlit Vault (USA).nes", SizeBytes: int64(len(starlit))},
		{RelPath: "Mecha Garden (Japan).nes", SizeBytes: int64(len(mecha))},
	}, time.Now()); err != nil {
		t.Fatal(err)
	}

	// A cache that describes ONLY one game, with real prose.
	cacheDir := CacheDirFor(filepath.Join(root, "cache"), sys)
	writeCacheDB(t, cacheDir, `<db>
  <resource id="`+sha1Hex(t, starlit)+`" type="description" source="ScreenScraper" timestamp="1">A vault. In space.</resource>
  <resource id="`+sha1Hex(t, starlit)+`" type="cover" source="ScreenScraper" timestamp="1">covers/starlit.png</resource>
</db>`)

	n, err := ApplyCacheEnrichment(st, sys, sysDir, cacheDir)
	if err != nil {
		t.Fatalf("ApplyCacheEnrichment: %v", err)
	}
	if n != 1 {
		t.Fatalf("ingested %d descriptions, want 1 (only the described game)", n)
	}
	rows, err := st.SystemGamesWithMeta("nes")
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	for _, r := range rows {
		got[r.RelPath] = r.Description
	}
	if got["Starlit Vault (USA).nes"] != "A vault. In space." {
		t.Fatalf("description not ingested verbatim: %q", got["Starlit Vault (USA).nes"])
	}
	if got["Mecha Garden (Japan).nes"] != "" {
		t.Fatalf("undescribed game must stay empty (honesty contract): %q", got["Mecha Garden (Japan).nes"])
	}

	// A later scrape whose cache lost the id must NOT wipe the stored text
	// (SetGameMeta's selective-write contract).
	writeCacheDB(t, cacheDir, `<?xml version="1.0"?><db></db>`)
	n, err = ApplyCacheEnrichment(st, sys, sysDir, cacheDir)
	if err != nil || n != 0 {
		t.Fatalf("empty-cache pass: n=%d err=%v, want 0/nil", n, err)
	}
	rows, _ = st.SystemGamesWithMeta("nes")
	for _, r := range rows {
		if r.RelPath == "Starlit Vault (USA).nes" && r.Description == "" {
			t.Fatal("empty cache pass wiped a previously stored description")
		}
	}
}

// TestApplyCacheEnrichmentTruncatesHugeDescriptions pins ADV-P7-04: a
// pathological cache description is bounded at ingest (rune-safe cut at
// maxIngestDescription) instead of riding multi-MB prose into the store
// and every generated launcher-DB line; normal-size text stays verbatim.
func TestApplyCacheEnrichmentTruncatesHugeDescriptions(t *testing.T) {
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
	huge := bytes.Repeat([]byte("z"), 8)
	normal := bytes.Repeat([]byte("n"), 8)
	for name, body := range map[string][]byte{
		"Huge Blurb (USA).nes":   huge,
		"Normal Blurb (USA).nes": normal,
	} {
		if err := os.WriteFile(filepath.Join(sysDir, name), body, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := st.ReplaceSystemGames("nes", []store.GameRow{
		{RelPath: "Huge Blurb (USA).nes", SizeBytes: int64(len(huge))},
		{RelPath: "Normal Blurb (USA).nes", SizeBytes: int64(len(normal))},
	}, time.Now()); err != nil {
		t.Fatal(err)
	}

	cacheDir := CacheDirFor(filepath.Join(root, "cache"), sys)
	writeCacheDB(t, cacheDir, `<db>
  <resource id="`+sha1Hex(t, huge)+`" type="description" source="s">`+strings.Repeat("prose ", maxIngestDescription)+`TAIL-NEVER-SERVED</resource>
  <resource id="`+sha1Hex(t, normal)+`" type="description" source="s">A perfectly ordinary blurb.</resource>
</db>`)

	n, err := ApplyCacheEnrichment(st, sys, sysDir, cacheDir)
	if err != nil {
		t.Fatalf("ApplyCacheEnrichment: %v", err)
	}
	if n != 2 {
		t.Fatalf("ingested %d descriptions, want 2", n)
	}
	rows, err := st.SystemGamesWithMeta("nes")
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	for _, r := range rows {
		got[r.RelPath] = r.Description
	}
	if l := len([]rune(got["Huge Blurb (USA).nes"])); l != maxIngestDescription {
		t.Fatalf("huge description stored at %d chars, want exactly %d", l, maxIngestDescription)
	}
	if strings.Contains(got["Huge Blurb (USA).nes"], "TAIL-NEVER-SERVED") {
		t.Fatal("truncation did not cut the tail — the bound is decorative")
	}
	if got["Normal Blurb (USA).nes"] != "A perfectly ordinary blurb." {
		t.Fatalf("normal description must stay verbatim: %q", got["Normal Blurb (USA).nes"])
	}
}

// ---- Issue #81: restart-safe sha1 fill (observability + abort durability) --

// captureLog redirects the standard logger into a buffer for the duration
// of f and returns what was written (the scanner's fill/skip lines are its
// only restart-skip observable; tests run sequentially — nothing in this
// package calls t.Parallel).
func captureLog(t *testing.T, f func()) string {
	t.Helper()
	var buf strings.Builder
	old := log.Writer()
	log.SetOutput(&buf)
	defer log.SetOutput(old)
	f()
	return buf.String()
}

// buildTestZip writes one valid single-entry zip and returns the SHA1 of
// the INNER contents (CacheID's zip keying).
func buildTestZip(t *testing.T, path, innerName string, body []byte) string {
	t.Helper()
	zf, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer zf.Close() //nolint:errcheck // test
	zw := zip.NewWriter(zf)
	w, err := zw.Create(innerName)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.Write(body); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return sha1Hex(t, body)
}

// gameSHA1 fetches one system game's stored sha1 by rel path ("" when the
// row is absent or unhashed).
func gameSHA1(t *testing.T, st *store.Store, systemKey, relPath string) string {
	t.Helper()
	page, err := st.ListGames(store.GameListOpts{SystemKey: systemKey})
	if err != nil {
		t.Fatal(err)
	}
	for _, g := range page.Games {
		if g.RelPath == relPath {
			d, err := st.GetGame(systemKey, g.ID)
			if err != nil {
				t.Fatal(err)
			}
			if d == nil {
				return ""
			}
			return d.SHA1
		}
	}
	return "\x00absent" // distinct from "present but NULL"
}

// TestScanSHA1RestartLifecycle pins the restart behavior the europa
// backfill made urgent (issue #81): across service restarts (fresh Scanner
// over the same store), unchanged files are never re-hashed, added files
// are hashed exactly once, removed files prune with their stale rows, and
// every fill announces itself in the journal (the ~2h silent window during
// europa's first boot was indistinguishable from a recurring cost).
//
// The skip proof is mechanical, not stylistic: A's CONTENT is replaced
// between scan 2's neighbors under an identical stat tuple — any re-hash
// attempt would persist the new id and fail the wantA assertions below.
func TestScanSHA1RestartLifecycle(t *testing.T) {
	root := t.TempDir()
	st, err := store.Open(filepath.Join(root, "arcade.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close() //nolint:errcheck // test

	tsv := filepath.Join(root, "cat.tsv")
	if err := os.WriteFile(tsv, []byte("nes\tNES\tfceumm\t-\tnes\t-\tcartridge\t-\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	sysDir := filepath.Join(root, "games", "nes")
	if err := os.MkdirAll(sysDir, 0o755); err != nil {
		t.Fatal(err)
	}
	cfg := Config{
		CatalogueTsv:  tsv,
		CartridgeRoot: filepath.Join(root, "games"),
		DBPath:        "unused",
	}

	bodyA1 := bytes.Repeat([]byte("a-first-"), 16) // 8-byte unit
	bodyA2 := bytes.Repeat([]byte("a-SECOND"), 16) // same length as bodyA1
	if len(bodyA1) != len(bodyA2) {
		t.Fatal("test bug: bodies must share one size to isolate content drift")
	}
	bodyB := bytes.Repeat([]byte("b-body--"), 16)
	bodyC := bytes.Repeat([]byte("c-body--"), 16)
	if err := os.WriteFile(filepath.Join(sysDir, "A (USA).nes"), bodyA1, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sysDir, "B (USA).nes"), bodyB, 0o644); err != nil {
		t.Fatal(err)
	}
	wantA := sha1Hex(t, bodyA1)

	// Scan 1 (first boot): both files hashed; the fill announces itself.
	var logs string
	logs = captureLog(t, func() {
		if _, err := New(cfg, st).Scan(); err != nil {
			t.Fatalf("scan 1: %v", err)
		}
	})
	if !strings.Contains(logs, "nes: filling sha1 for 2 new game file(s)") {
		t.Fatalf("scan 1 logged %q, want the nes fill line for 2 files", logs)
	}
	if got := gameSHA1(t, st, "nes", "A (USA).nes"); got != wantA {
		t.Fatalf("A sha1 = %q, want %q", got, wantA)
	}
	wantB := sha1Hex(t, bodyB)
	if got := gameSHA1(t, st, "nes", "B (USA).nes"); got != wantB {
		t.Fatalf("B sha1 = %q, want %q", got, wantB)
	}

	// Scan 2 (simulated restart): fresh Scanner over the same store. A's
	// bytes changed in place at an unchanged path and size (mtime moves,
	// but the fill gate keys on sha1 IS NULL, never stat) — if anything
	// re-attempted it, the new id would land below. Nothing is missing,
	// so no fill line may appear.
	if err := os.WriteFile(filepath.Join(sysDir, "A (USA).nes"), bodyA2, 0o644); err != nil {
		t.Fatal(err)
	}
	logs = captureLog(t, func() {
		if _, err := New(cfg, st).Scan(); err != nil {
			t.Fatalf("scan 2: %v", err)
		}
	})
	if strings.Contains(logs, "filling sha1") {
		t.Fatalf("restart rescan re-entered hashing: %q", logs)
	}
	if got := gameSHA1(t, st, "nes", "A (USA).nes"); got != wantA {
		t.Fatalf("unchanged-path sha1 moved to %q after restart scan — fill-once violated", got)
	}
	if got := gameSHA1(t, st, "nes", "B (USA).nes"); got != wantB {
		t.Fatalf("B sha1 disturbed without cause: %q", got)
	}

	// Scan 3 (restart, one added file): only C hashes; siblings untouched.
	wantC := buildTestZip(t, filepath.Join(sysDir, "C (USA).zip"), "Inner (USA).nds", bodyC)
	logs = captureLog(t, func() {
		if _, err := New(cfg, st).Scan(); err != nil {
			t.Fatalf("scan 3: %v", err)
		}
	})
	if !strings.Contains(logs, "nes: filling sha1 for 1 new game file(s)") {
		t.Fatalf("scan 3 logged %q, want the nes fill line for exactly 1 file", logs)
	}
	if got := gameSHA1(t, st, "nes", "C (USA).zip"); got != wantC {
		t.Fatalf("C zip sha1 = %q, want inner %q", got, wantC)
	}
	if got := gameSHA1(t, st, "nes", "A (USA).nes"); got != wantA {
		t.Fatalf("A sha1 = %q after scan 3, want untouched %q", got, wantA)
	}

	// Scan 4 (removal): B vanishes from disk, its row prunes with it.
	if err := os.Remove(filepath.Join(sysDir, "B (USA).nes")); err != nil {
		t.Fatal(err)
	}
	if _, err := New(cfg, st).Scan(); err != nil {
		t.Fatalf("scan 4: %v", err)
	}
	switch got := gameSHA1(t, st, "nes", "B (USA).nes"); got {
	case "\x00absent":
		// pruned, as required
	case "":
		t.Fatal("B row survived removal with a NULL sha1 (prune missed it)")
	default:
		t.Fatal("B row survived removal with a live sha1 (prune missed it)")
	}
	if got := gameSHA1(t, st, "nes", "A (USA).nes"); got != wantA {
		t.Fatalf("A sha1 = %q after B's prune scan, want %q", got, wantA)
	}
}

// TestPersistSHA1FlushSurvivesHashFailures pins the batched flush contract
// (issue #81): checksums land in bounded batches DURING the walk, so one
// unhashable file neither blocks its successors nor discards the batches
// already persisted — the property that bounds an interrupted scan's lost
// work to at most one batch instead of a whole system.
func TestPersistSHA1FlushSurvivesHashFailures(t *testing.T) {
	root := t.TempDir()
	st, err := store.Open(filepath.Join(root, "arcade.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close() //nolint:errcheck // test
	tsv := filepath.Join(root, "cat.tsv")
	if err := os.WriteFile(tsv, []byte("nes\tNES\tfceumm\t-\tnes\t-\tcartridge\t-\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	sysDir := filepath.Join(root, "games", "nes")
	if err := os.MkdirAll(sysDir, 0o755); err != nil {
		t.Fatal(err)
	}
	bodies := map[string][]byte{
		"F1 (USA).nes": bytes.Repeat([]byte("one"), 8),
		"F2 (USA).nes": bytes.Repeat([]byte("two"), 8),
		"F4 (USA).nes": bytes.Repeat([]byte("four"), 8),
	}
	for name, body := range bodies {
		if err := os.WriteFile(filepath.Join(sysDir, name), body, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// F3 is a corrupt zip: CacheID fails on open, the documented skip path.
	if err := os.WriteFile(filepath.Join(sysDir, "F3 (USA).zip"), []byte("not a zip file"), 0o644); err != nil {
		t.Fatal(err)
	}

	old := sha1FlushBatch
	shrunk := 1 // flush after EVERY success: maximal batching exercise
	sha1FlushBatch = shrunk
	defer func() { sha1FlushBatch = old }()

	var logs string
	logs = captureLog(t, func() {
		if _, err := New(Config{
			CatalogueTsv:  tsv,
			CartridgeRoot: filepath.Join(root, "games"),
			DBPath:        "unused",
		}, st).Scan(); err != nil {
			t.Fatalf("scan: %v", err)
		}
	})
	for name, body := range bodies {
		if got := gameSHA1(t, st, "nes", name); got != sha1Hex(t, body) {
			t.Fatalf("%s sha1 = %q, want %q (a later failure must not discard earlier batches)", name, got, sha1Hex(t, body))
		}
	}
	if got := gameSHA1(t, st, "nes", "F3 (USA).zip"); got != "" {
		t.Fatalf("corrupt zip persisted sha1 %q, want empty", got)
	}
	if !strings.Contains(logs, "not hashed for sha1") {
		t.Fatalf("skipped-file log missing from %q (documented misses must stay visible)", logs)
	}
}

// TestPersistSHA1FlushFailureStopsAndPreserves pins the abort contract the
// batching exists for (issue #81, ADV-01): when the store rejects a batch,
// every EARLIER batch stays persisted, hashing STOPS (later candidates are
// never even read), the abort is loud on the journal, and the run carries
// a warning — a mid-backfill interruption must be visible and cheap.
func TestPersistSHA1FlushFailureStopsAndPreserves(t *testing.T) {
	root := t.TempDir()
	st, err := store.Open(filepath.Join(root, "arcade.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close() //nolint:errcheck // test
	tsv := filepath.Join(root, "cat.tsv")
	if err := os.WriteFile(tsv, []byte("nes\tNES\tfceumm\t-\tnes\t-\tcartridge\t-\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	sysDir := filepath.Join(root, "games", "nes")
	if err := os.MkdirAll(sysDir, 0o755); err != nil {
		t.Fatal(err)
	}
	bodies := map[string][]byte{
		"G1 (USA).nes": bytes.Repeat([]byte("one"), 8),
		"G2 (USA).nes": bytes.Repeat([]byte("two"), 8),
		"G3 (USA).nes": bytes.Repeat([]byte("three"), 8),
		"G4 (USA).nes": bytes.Repeat([]byte("four"), 8),
	}
	for name, body := range bodies {
		if err := os.WriteFile(filepath.Join(sysDir, name), body, 0o644); err != nil {
			t.Fatal(err)
		}
	}

	oldBatch := sha1FlushBatch
	oldFlush := sha1Flush
	sha1FlushBatch = 1 // one file per flush: precise call accounting
	flushCalls := 0
	sha1Flush = func(st *store.Store, systemKey string, cks []store.GameChecksum) error {
		flushCalls++
		if flushCalls >= 2 {
			return fmt.Errorf("injected store failure #%d", flushCalls)
		}
		return st.SetGameChecksums(systemKey, cks)
	}
	defer func() { sha1FlushBatch = oldBatch; sha1Flush = oldFlush }()

	var res Result
	var logs string
	logs = captureLog(t, func() {
		// Scan returns nil error (the abort is a warning, not a failure —
		// same resilience posture as any per-system warning).
		r, err := New(Config{
			CatalogueTsv:  tsv,
			CartridgeRoot: filepath.Join(root, "games"),
			DBPath:        "unused",
		}, st).Scan()
		if err != nil {
			t.Fatalf("scan: %v", err)
		}
		res = r
	})
	if flushCalls != 2 {
		t.Fatalf("flush called %d times, want exactly 2 (one success, one failure) — hashing must STOP after a failed flush", flushCalls)
	}
	if got := gameSHA1(t, st, "nes", "G1 (USA).nes"); got != sha1Hex(t, bodies["G1 (USA).nes"]) {
		t.Fatalf("G1 sha1 = %q, want the pre-abort batch preserved", got)
	}
	for _, name := range []string{"G2 (USA).nes", "G3 (USA).nes", "G4 (USA).nes"} {
		if got := gameSHA1(t, st, "nes", name); got != "" {
			t.Fatalf("%s sha1 = %q, want NULL (aborted fill must not half-persist)", name, got)
		}
	}
	warned := false
	for _, w := range res.Warnings {
		if strings.Contains(w, "persist sha1") && strings.Contains(w, "injected store failure") {
			warned = true
		}
	}
	if !warned {
		t.Fatalf("no persist-sha1 warning among %v", res.Warnings)
	}
	if !strings.Contains(logs, "sha1 fill aborted after 1 hashed") {
		t.Fatalf("abort not logged in %q", logs)
	}
}

// TestScanSHA1AllSkippedLogsDoneLine pins the honest-outcome half of the
// observability fix (issue #81, ADV-02): systems whose only candidates are
// permanent misses (oversized here; corrupt in the wild) reprint the fill
// line every boot — the paired done line is what marks those boots as
// no-op retries instead of real hashing work.
func TestScanSHA1AllSkippedLogsDoneLine(t *testing.T) {
	root := t.TempDir()
	st, err := store.Open(filepath.Join(root, "arcade.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close() //nolint:errcheck // test
	tsv := filepath.Join(root, "cat.tsv")
	if err := os.WriteFile(tsv, []byte("nes\tNES\tfceumm\t-\tnes\t-\tcartridge\t-\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	sysDir := filepath.Join(root, "games", "nes")
	if err := os.MkdirAll(sysDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := bytes.Repeat([]byte("over-the-line"), 64)
	if err := os.WriteFile(filepath.Join(sysDir, "Huge (USA).nes"), body, 0o644); err != nil {
		t.Fatal(err)
	}
	old := romHashSizeLimit
	romHashSizeLimit = 16 // everything in this tree exceeds the cap
	defer func() { romHashSizeLimit = old }()

	var logs string
	logs = captureLog(t, func() {
		if _, err := New(Config{
			CatalogueTsv:  tsv,
			CartridgeRoot: filepath.Join(root, "games"),
			DBPath:        "unused",
		}, st).Scan(); err != nil {
			t.Fatalf("scan: %v", err)
		}
	})
	if !strings.Contains(logs, "filling sha1 for 1 new game file(s)") ||
		!strings.Contains(logs, "sha1 fill done: 0 hashed, 1 skipped") {
		t.Fatalf("all-skipped fill logged %q, want the fill+done pair with 0 hashed", logs)
	}
	if got := gameSHA1(t, st, "nes", "Huge (USA).nes"); got != "" {
		t.Fatalf("oversized row persisted sha1 %q", got)
	}
}
