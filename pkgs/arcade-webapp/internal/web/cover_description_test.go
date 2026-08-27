package web

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// TestArtSkyscraperFallback verifies that /art serves a real cover from the
// Skyscraper cache when ARCADE_WEBAPP_SKYSCRAPER_CACHE_DIR is wired — the
// PS1 1.5G demo (790M covers under covers/screenscraper/<id>.png).
func TestArtSkyscraperFallback(t *testing.T) {
	root := t.TempDir()
	st, scan := fixtureScan(t, root)
	cacheRoot := filepath.Join(root, "metadata", "skyscraper-cache")

	// Pick the first game (Astral Almari sorts first, but use store order).
	pg, err := st.ListGames(store.GameListOpts{Limit: 1})
	if err != nil || len(pg.Games) == 0 {
		t.Fatalf("ListGames: %v", pg)
	}
	g := pg.Games[0]
	full, err := st.GetGame(g.SystemKey, g.ID)
	if err != nil || full == nil {
		t.Fatalf("GetGame: %v %v", full, err)
	}
	id := full.SHA1
	if id == "" {
		t.Fatalf("game %s/%d has empty SHA1 (scanner should have filled it)", g.SystemKey, g.ID)
	}
	// Ensure the per-system cache dir exists and contains a cover entry for this id.
	sysCache := filepath.Join(cacheRoot, g.SystemKey)
	if err := os.MkdirAll(filepath.Join(sysCache, "covers", "screenscraper"), 0o755); err != nil {
		t.Fatal(err)
	}
	// Minimal 1x1 PNG (transparent) — valid image/png, 67 bytes after header.
	// Generate a tiny valid PNG via raw bytes (IHDR+IEND) so ServeContent sniffs png.
	png := []byte{
		0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
		0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
		0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
		0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
		0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
		0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
		0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
		0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
		0x42, 0x60, 0x82,
	}
	if err := os.WriteFile(filepath.Join(sysCache, "covers", "screenscraper", id+".png"), png, 0o644); err != nil {
		t.Fatal(err)
	}
	// Also refresh db.xml so ReadCacheCoverage sees the cover (and the fallback probe also covers the no-db case).
	_ = os.WriteFile(filepath.Join(sysCache, "db.xml"), []byte(fmt.Sprintf(`<db><resource id="%s" type="cover" source="ScreenScraper">covers/screenscraper/%s.png</resource></db>`, id, id)), 0o644)

	// Build server with cache fallback (no artDir).
	srv, err := New(st, scan, WithCacheDir(cacheRoot))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	// Ensure the scan's SHA1-driven flag is set so the coverage strip would see it (not required for art fallback, but mirrors live).
	_ = st.SetSystemScrapeFlags(g.SystemKey, []store.GameScrapeFlag{{RelPath: g.RelPath, Cover: true}})

	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", fmt.Sprintf("/art/%s/%d", g.SystemKey, g.ID), nil)
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /art: status %d, want 200", rec.Code)
	}
	ct := rec.Header().Get("Content-Type")
	if !strings.Contains(ct, "image/png") && !strings.Contains(ct, "image/jpeg") {
		t.Fatalf("Content-Type = %q, want image/png or jpeg (real cover, not svg)", ct)
	}
	if bytes.Equal(rec.Body.Bytes(), png) == false && !strings.Contains(rec.Header().Get("Content-Type"), "png") {
		// Served bytes may have been sniffed; just ensure not SVG.
		if strings.Contains(string(rec.Body.Bytes()), "<svg") {
			t.Error("body is SVG fallback, want real cover bytes")
		}
	}
	if cc := rec.Header().Get("Cache-Control"); !strings.Contains(cc, "public") {
		t.Errorf("Cache-Control = %q, want public", cc)
	}

	// A game without a cover must still fall back to SVG.
	pg2, _ := st.ListGames(store.GameListOpts{Limit: 10})
	var uncovered *store.GameSummary
	for _, gg := range pg2.Games {
		if gg.ID != g.ID {
			uncovered = &gg
			break
		}
	}
	if uncovered != nil {
		rec2 := httptest.NewRecorder()
		req2 := httptest.NewRequest("GET", fmt.Sprintf("/art/%s/%d", uncovered.SystemKey, uncovered.ID), nil)
		srv.Handler().ServeHTTP(rec2, req2)
		if rec2.Code != http.StatusOK {
			t.Fatalf("GET /art uncovered: %d", rec2.Code)
		}
		if ct2 := rec2.Header().Get("Content-Type"); ct2 != "image/svg+xml" {
			t.Errorf("uncovered cover Content-Type = %q, want image/svg+xml fallback", ct2)
		}
	}
}

// TestLibraryAndGameDetailShowDescription verifies that ingested prose
// (4000 runes via ApplyCacheEnrichment) surfaces truncated on cards and
// fully on the detail page, with honest fallback when empty.
func TestLibraryAndGameDetailShowDescription(t *testing.T) {
	srv := newTestServer(t)
	// Pick two games: one will get prose, one stays empty.
	games := firstGames(t, srv.st, 2)
	a := games[0]
	b := games[1]

	prose := "A vault. In space. The player unlocks ancient mechanisms while a mournful synth hums."
	if err := srv.st.SetGameMeta(a.SystemKey, []store.GameMeta{{RelPath: a.RelPath, Description: prose}}); err != nil {
		t.Fatalf("SetGameMeta: %v", err)
	}
	// Also flip the flag so the detail page's ✓ reads true (store layer keeps them separate).
	_ = srv.st.SetSystemScrapeFlags(a.SystemKey, []store.GameScrapeFlag{{RelPath: a.RelPath, Description: true}})

	// Library card shows truncated prose.
	rec := get(t, srv.Handler(), "/library")
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /library: %d", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "A vault. In space.") {
		t.Error("library page missing ingested description snippet on card")
	}
	// The other game's card must NOT carry the prose.
	// (Simple check: prose appears once, not attached to every card.)
	if strings.Count(body, "A vault. In space.") != 1 {
		t.Errorf("description snippet count = %d, want 1 (only the enriched card)", strings.Count(body, "A vault. In space."))
	}

	// Game detail: full prose with typography.
	rec = get(t, srv.Handler(), fmt.Sprintf("/systems/%s/games/%d", a.SystemKey, a.ID))
	if rec.Code != http.StatusOK {
		t.Fatalf("GET detail enriched: %d", rec.Code)
	}
	dBody := rec.Body.String()
	if !strings.Contains(dBody, prose) {
		t.Error("detail page missing full ingested description")
	}
	if !strings.Contains(dBody, `class="game-description"`) {
		t.Error("detail page missing description container")
	}

	// Detail fallback for undescribed game.
	rec = get(t, srv.Handler(), fmt.Sprintf("/systems/%s/games/%d", b.SystemKey, b.ID))
	if rec.Code != http.StatusOK {
		t.Fatalf("GET detail undescribed: %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "no description yet") {
		t.Error("undescribed detail missing fallback hint")
	}
}

// TestMetadataCoverStrip verifies the tiny cover strip (3-4 thumbnails via /art).
func TestMetadataCoverStrip(t *testing.T) {
	root := t.TempDir()
	st, scan := fixtureScan(t, root)
	// Mark one system as having covers and provide sample ids.
	pg, _ := st.ListGames(store.GameListOpts{SystemKey: "nes", Limit: 5})
	var flags []store.GameScrapeFlag
	for _, g := range pg.Games {
		flags = append(flags, store.GameScrapeFlag{RelPath: g.RelPath, Cover: true})
	}
	if err := st.SetSystemScrapeFlags("nes", flags); err != nil {
		t.Fatal(err)
	}
	// Provide a dummy scrape driver config so the page renders as configured (otherwise CanScrape false but strip still renders).
	srv, err := New(st, scan)
	if err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", "/metadata", nil)
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /metadata: %d", rec.Code)
	}
	body := rec.Body.String()
	// The strip should contain at least one /art/nes/<id> thumbnail when covers exist.
	if !strings.Contains(body, `class="cover-thumb"`) {
		t.Error("metadata page missing cover strip thumbnails (HasCover>0 should render 3-4 samples via /art)")
	}
	if !strings.Contains(body, `/art/nes/`) {
		t.Error("cover strip missing /art/ URLs")
	}
}

// TestArtFallsBackToSVGWhenCacheDirEmpty ensures empty cacheDir still serves SVG.
func TestArtFallsBackToSVGWhenCacheDirEmpty(t *testing.T) {
	srv := newTestServer(t)
	g := firstGames(t, srv.st, 1)[0]
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("GET", fmt.Sprintf("/art/%s/%d", g.SystemKey, g.ID), nil)
	// Server without WithCacheDir (cacheDir == "")
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /art: %d", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "image/svg+xml" {
		t.Errorf("empty cacheDir Content-Type = %q, want image/svg+xml", ct)
	}
	// With empty dir explicitly, same.
	srv2, _ := New(srv.st, srv.scan, WithCacheDir(""))
	rec2 := httptest.NewRecorder()
	srv2.Handler().ServeHTTP(rec2, httptest.NewRequest("GET", fmt.Sprintf("/art/%s/%d", g.SystemKey, g.ID), nil))
	if ct := rec2.Header().Get("Content-Type"); ct != "image/svg+xml" {
		t.Errorf("WithCacheDir(\"\") Content-Type = %q, want svg", ct)
	}
}

func TestStoreCoverSamples(t *testing.T) {
	srv := newTestServer(t)
	// Initially no covers flag set → empty.
	if got, _ := srv.st.CoverSamples("nes", 4); len(got) != 0 {
		t.Fatalf("cover samples before flags = %v, want empty", got)
	}
	pg, _ := srv.st.ListGames(store.GameListOpts{SystemKey: "nes"})
	if len(pg.Games) < 2 {
		t.Fatal("need nes games")
	}
	if err := srv.st.SetSystemScrapeFlags("nes", []store.GameScrapeFlag{
		{RelPath: pg.Games[0].RelPath, Cover: true},
		{RelPath: pg.Games[1].RelPath, Cover: true},
	}); err != nil {
		t.Fatal(err)
	}
	got, err := srv.st.CoverSamples("nes", 4)
	if err != nil || len(got) != 2 {
		t.Fatalf("CoverSamples = %v, %v; want 2", got, err)
	}
}

func TestStoreDescriptionRoundTrip(t *testing.T) {
	srv := newTestServer(t)
	g := firstGames(t, srv.st, 1)[0]
	// Initially empty.
	if got, _ := srv.st.GetGame(g.SystemKey, g.ID); got.Description != "" {
		t.Fatalf("initial description = %q, want empty", got.Description)
	}
	long := strings.Repeat("x", 5000)
	if err := srv.st.SetGameMeta(g.SystemKey, []store.GameMeta{{RelPath: g.RelPath, Description: long}}); err != nil {
		t.Fatal(err)
	}
	got, _ := srv.st.GetGame(g.SystemKey, g.ID)
	if got.Description != long {
		t.Fatalf("description len = %d, want %d", len(got.Description), len(long))
	}
	// ListGames also carries it.
	pg, _ := srv.st.ListGames(store.GameListOpts{SystemKey: g.SystemKey})
	found := false
	for _, gg := range pg.Games {
		if gg.ID == g.ID && gg.Description == long {
			found = true
		}
	}
	if !found {
		t.Error("ListGames missing ingested description")
	}
}
