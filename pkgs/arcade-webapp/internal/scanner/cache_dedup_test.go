package scanner

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// TestApplyCacheBothSingleParseAndHash proves the dedup contract:
// one ReadCacheCoverage parse and at most one CacheID per game for the
// whole system, even though both flag and enrichment writes happen.
// Before the fix the pair did 2 parses + 2*N hashes (hours-scale on
// europa's 27k files / 7.1 TiB). After: 1 parse + N hashes.
func TestApplyCacheBothSingleParseAndHash(t *testing.T) {
	root := t.TempDir()
	st, err := store.Open(filepath.Join(root, "arcade.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	sys := store.SystemRow{Key: "nes", Collection: "NES", Bucket: "cartridge", SortOrder: 1, Extensions: `["nes"]`}
	if err := st.UpsertSystems([]store.SystemRow{sys}); err != nil {
		t.Fatal(err)
	}
	sysDir := filepath.Join(root, "games", "nes")
	if err := os.MkdirAll(sysDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// Two games, each will be hashed once.
	bodies := map[string][]byte{
		"A (USA).nes": bytes.Repeat([]byte("alpha"), 8),
		"B (USA).nes": bytes.Repeat([]byte("beta"), 8),
	}
	for name, body := range bodies {
		if err := os.WriteFile(filepath.Join(sysDir, name), body, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := st.ReplaceSystemGames("nes", []store.GameRow{
		{RelPath: "A (USA).nes", SizeBytes: int64(len(bodies["A (USA).nes"]))},
		{RelPath: "B (USA).nes", SizeBytes: int64(len(bodies["B (USA).nes"]))},
	}, time.Now()); err != nil {
		t.Fatal(err)
	}
	// Cache describes both games (desc+cover) and carries text for both.
	cacheDir := CacheDirFor(filepath.Join(root, "cache"), sys)
	writeCacheDB(t, cacheDir, `<db>
  <resource id="`+sha1Hex(t, bodies["A (USA).nes"])+`" type="description" source="s">Desc A</resource>
  <resource id="`+sha1Hex(t, bodies["A (USA).nes"])+`" type="cover" source="s">covers/a.png</resource>
  <resource id="`+sha1Hex(t, bodies["B (USA).nes"])+`" type="description" source="s">Desc B</resource>
  <resource id="`+sha1Hex(t, bodies["B (USA).nes"])+`" type="cover" source="s">covers/b.png</resource>
</db>`)

	// Fault-inject counting via the var pattern (like sha1Flush/romHashSizeLimit).
	origParse := readCacheCoverageFn
	origHash := cacheIDFn
	defer func() { readCacheCoverageFn = origParse; cacheIDFn = origHash }()

	parseCalls := 0
	readCacheCoverageFn = func(dir string) (*CacheCoverage, error) {
		parseCalls++
		return origParse(dir)
	}
	hashCalls := 0
	cacheIDFn = func(path string) (string, error) {
		hashCalls++
		return origHash(path)
	}

	n, covErr, enrichErr := ApplyCacheBoth(st, sys, sysDir, cacheDir)
	if covErr != nil {
		t.Fatalf("ApplyCacheBoth covErr %v", covErr)
	}
	if enrichErr != nil {
		t.Fatalf("ApplyCacheBoth enrichErr %v", enrichErr)
	}
	if n != 2 {
		t.Fatalf("enriched %d, want 2", n)
	}
	if parseCalls != 1 {
		t.Fatalf("ReadCacheCoverage called %d times, want 1 (was 2 before fix)", parseCalls)
	}
	if hashCalls != 2 {
		t.Fatalf("CacheID called %d times, want 2 (one per game, was 4 before fix)", hashCalls)
	}
	// Semantics preserved: flags and descriptions both landed.
	page, _ := st.ListGames(store.GameListOpts{SystemKey: "nes"})
	for _, g := range page.Games {
		d, _ := st.GetGame("nes", g.ID)
		if !d.HasDescription || !d.HasCover {
			t.Errorf("%s flags desc:%v cover:%v, want both true", g.RelPath, d.HasDescription, d.HasCover)
		}
	}
	rows, _ := st.SystemGamesWithMeta("nes")
	got := map[string]string{}
	for _, r := range rows {
		got[r.RelPath] = r.Description
	}
	if got["A (USA).nes"] != "Desc A" || got["B (USA).nes"] != "Desc B" {
		t.Fatalf("descriptions not both ingested verbatim: %+v", got)
	}
}

// TestApplyCacheWrappersSingleParseAndHash proves the thin wrappers each
// also use a single parse/hash per call (the per-call dedup baseline).
func TestApplyCacheWrappersSingleParseAndHash(t *testing.T) {
	root := t.TempDir()
	st, err := store.Open(filepath.Join(root, "arcade.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	sys := store.SystemRow{Key: "nes", Collection: "NES", Bucket: "cartridge", SortOrder: 1, Extensions: `["nes"]`}
	if err := st.UpsertSystems([]store.SystemRow{sys}); err != nil {
		t.Fatal(err)
	}
	sysDir := filepath.Join(root, "games", "nes")
	if err := os.MkdirAll(sysDir, 0o755); err != nil {
		t.Fatal(err)
	}
	body := bytes.Repeat([]byte("solo"), 8)
	if err := os.WriteFile(filepath.Join(sysDir, "Solo (USA).nes"), body, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := st.ReplaceSystemGames("nes", []store.GameRow{{RelPath: "Solo (USA).nes", SizeBytes: int64(len(body))}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	cacheDir := CacheDirFor(filepath.Join(root, "cache"), sys)
	writeCacheDB(t, cacheDir, `<db><resource id="`+sha1Hex(t, body)+`" type="description">text</resource><resource id="`+sha1Hex(t, body)+`" type="cover">c</resource></db>`)

	origParse := readCacheCoverageFn
	origHash := cacheIDFn
	defer func() { readCacheCoverageFn = origParse; cacheIDFn = origHash }()

	for _, tc := range []struct {
		name string
		call func() error
	}{
		{"flags", func() error { return ApplyCacheFlags(st, sys, sysDir, cacheDir) }},
		{"enrich", func() error { _, err := ApplyCacheEnrichment(st, sys, sysDir, cacheDir); return err }},
	} {
		parseCalls, hashCalls := 0, 0
		readCacheCoverageFn = func(dir string) (*CacheCoverage, error) { parseCalls++; return origParse(dir) }
		cacheIDFn = func(path string) (string, error) { hashCalls++; return origHash(path) }
		if err := tc.call(); err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		if parseCalls != 1 {
			t.Errorf("%s: parses=%d want 1", tc.name, parseCalls)
		}
		if hashCalls != 1 {
			t.Errorf("%s: hashes=%d want 1", tc.name, hashCalls)
		}
	}
}

// TestApplyCacheBothZeroGamesOrZeroCache ensures the early-return paths
// still clear flags and return 0 enrichments with single parse/hash.
func TestApplyCacheBothZeroGamesOrZeroCache(t *testing.T) {
	root := t.TempDir()
	st, err := store.Open(filepath.Join(root, "arcade.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	sys := store.SystemRow{Key: "nes", Collection: "NES", Bucket: "cartridge", SortOrder: 1, Extensions: `["nes"]`}
	if err := st.UpsertSystems([]store.SystemRow{sys}); err != nil {
		t.Fatal(err)
	}
	sysDir := filepath.Join(root, "games", "nes")
	if err := os.MkdirAll(sysDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// Zero games: empty directory, no rows.
	cacheDir := CacheDirFor(filepath.Join(root, "cache"), sys)
	writeCacheDB(t, cacheDir, `<db><resource id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" type="description">x</resource></db>`)
	n, covErr, enrichErr := ApplyCacheBoth(st, sys, sysDir, cacheDir)
	if covErr != nil || enrichErr != nil {
		t.Fatalf("zero-games errs %v / %v", covErr, enrichErr)
	}
	if n != 0 {
		t.Fatalf("zero-games enriched %d want 0", n)
	}
	// Zero cache entries: no db.xml (absent -> zero-value).
	body := bytes.Repeat([]byte("g"), 8)
	if err := os.WriteFile(filepath.Join(sysDir, "G (USA).nes"), body, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := st.ReplaceSystemGames("nes", []store.GameRow{{RelPath: "G (USA).nes", SizeBytes: int64(len(body))}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	// Put a flag first so we can see it cleared.
	if err := ApplyCacheFlags(st, sys, sysDir, cacheDir); err != nil {
		t.Fatal(err)
	}
	// Now wipe cache.
	if err := os.Remove(filepath.Join(cacheDir, "db.xml")); err != nil {
		t.Fatal(err)
	}
	n, covErr, enrichErr = ApplyCacheBoth(st, sys, sysDir, cacheDir)
	if covErr != nil || enrichErr != nil {
		t.Fatalf("zero-cache errs %v / %v", covErr, enrichErr)
	}
	if n != 0 {
		t.Fatalf("zero-cache enriched %d want 0", n)
	}
	page, _ := st.ListGames(store.GameListOpts{SystemKey: "nes"})
	d, _ := st.GetGame("nes", page.Games[0].ID)
	if d.HasDescription || d.HasCover {
		t.Errorf("flags after wipe %+v want both false", d)
	}
}

// TestApplyCacheBothPreservesSemantics pins the exact flag/enrichment
// contracts after the dedup: oversized stays false, truncated rune-safe,
// empty never wipes, corrupt propagates with correct prefixes.
func TestApplyCacheBothPreservesSemantics(t *testing.T) {
	root := t.TempDir()
	st, err := store.Open(filepath.Join(root, "arcade.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	sys := store.SystemRow{Key: "nes", Collection: "NES", Bucket: "cartridge", SortOrder: 1, Extensions: `["nes"]`}
	if err := st.UpsertSystems([]store.SystemRow{sys}); err != nil {
		t.Fatal(err)
	}
	sysDir := filepath.Join(root, "games", "nes")
	if err := os.MkdirAll(sysDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// Setup: two games, one oversized, one normal with huge description.
	normalBody := bytes.Repeat([]byte("n"), 8)
	hugeBody := bytes.Repeat([]byte("z"), 8)
	if err := os.WriteFile(filepath.Join(sysDir, "Normal (USA).nes"), normalBody, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sysDir, "Huge (USA).nes"), hugeBody, 0o644); err != nil {
		t.Fatal(err)
	}
	oversizedBody := bytes.Repeat([]byte("o"), 32)
	if err := os.WriteFile(filepath.Join(sysDir, "Oversized (USA).nes"), oversizedBody, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := st.ReplaceSystemGames("nes", []store.GameRow{
		{RelPath: "Normal (USA).nes", SizeBytes: int64(len(normalBody))},
		{RelPath: "Huge (USA).nes", SizeBytes: int64(len(hugeBody))},
		{RelPath: "Oversized (USA).nes", SizeBytes: int64(len(oversizedBody))},
	}, time.Now()); err != nil {
		t.Fatal(err)
	}
	cacheDir := CacheDirFor(filepath.Join(root, "cache"), sys)
	// Huge description exceeds maxIngestDescription.
	writeCacheDB(t, cacheDir, `<db>
  <resource id="`+sha1Hex(t, normalBody)+`" type="description">Keep me</resource>
  <resource id="`+sha1Hex(t, hugeBody)+`" type="description">`+strings.Repeat("x", maxIngestDescription+10)+`</resource>
  <resource id="`+sha1Hex(t, oversizedBody)+`" type="description">For oversized</resource>
  <resource id="`+sha1Hex(t, normalBody)+`" type="cover">covers/n.png</resource>
</db>`)

	oldLimit := romHashSizeLimit
	romHashSizeLimit = 16 // oversized (32) exceeds, others (8) hash
	defer func() { romHashSizeLimit = oldLimit }()

	n, covErr, enrichErr := ApplyCacheBoth(st, sys, sysDir, cacheDir)
	if covErr != nil || enrichErr != nil {
		t.Fatalf("both errs %v / %v", covErr, enrichErr)
	}
	if n != 2 {
		t.Fatalf("enriched %d want 2 (normal+huge, oversized skipped)", n)
	}
	page, _ := st.ListGames(store.GameListOpts{SystemKey: "nes"})
	byRel := map[string]int64{}
	for _, g := range page.Games {
		byRel[g.RelPath] = g.ID
	}
	// Oversized stays false.
	dOver, _ := st.GetGame("nes", byRel["Oversized (USA).nes"])
	if dOver.HasDescription || dOver.HasCover {
		t.Error("oversized must stay unflagged")
	}
	// Normal flagged.
	dNormal, _ := st.GetGame("nes", byRel["Normal (USA).nes"])
	if !dNormal.HasDescription || !dNormal.HasCover {
		t.Error("normal must be flagged desc+cover")
	}
	// Huge truncated rune-safe and not wiping.
	rows, _ := st.SystemGamesWithMeta("nes")
	got := map[string]string{}
	for _, r := range rows {
		got[r.RelPath] = r.Description
	}
	if l := len([]rune(got["Huge (USA).nes"])); l != maxIngestDescription {
		t.Fatalf("huge truncated to %d runes want %d", l, maxIngestDescription)
	}
	if got["Normal (USA).nes"] != "Keep me" {
		t.Fatalf("normal description %q want Keep me", got["Normal (USA).nes"])
	}
	if got["Oversized (USA).nes"] != "" {
		t.Fatalf("oversized description must stay empty")
	}
	// Empty cache pass must not wipe.
	writeCacheDB(t, cacheDir, `<db></db>`)
	n, covErr, enrichErr = ApplyCacheBoth(st, sys, sysDir, cacheDir)
	if covErr != nil || enrichErr != nil || n != 0 {
		t.Fatalf("empty cache both %d %v %v want 0 nil nil", n, covErr, enrichErr)
	}
	rows, _ = st.SystemGamesWithMeta("nes")
	for _, r := range rows {
		if r.RelPath == "Normal (USA).nes" && r.Description == "" {
			t.Fatal("empty cache wipe: stored description lost")
		}
	}
	// Corrupt propagates with correct prefixes.
	writeCacheDB(t, cacheDir, `<db><resource`)
	_, covErr, enrichErr = ApplyCacheBoth(st, sys, sysDir, cacheDir)
	if covErr == nil || !strings.Contains(covErr.Error(), "coverage") {
		t.Fatalf("corrupt covErr %v want coverage prefix", covErr)
	}
	if enrichErr == nil || !strings.Contains(enrichErr.Error(), "enrichment") {
		t.Fatalf("corrupt enrichErr %v want enrichment prefix", enrichErr)
	}
	// Absent -> zero-value not error.
	if err := os.Remove(filepath.Join(cacheDir, "db.xml")); err != nil && !errors.Is(err, os.ErrNotExist) {
		t.Fatal(err)
	}
	n, covErr, enrichErr = ApplyCacheBoth(st, sys, sysDir, cacheDir)
	if covErr != nil || enrichErr != nil {
		t.Fatalf("absent errs %v %v want nil", covErr, enrichErr)
	}
	if n != 0 {
		t.Fatalf("absent enriched %d want 0", n)
	}
}
