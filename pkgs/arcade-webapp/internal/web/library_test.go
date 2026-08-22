package web

import (
	"bytes"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// firstGames pulls the first n library rows (title sort — the same order
// page 1 renders) straight from the store, so tests address real ids
// instead of assuming the fixture scan's autoincrement sequence.
func firstGames(t *testing.T, s *store.Store, n int) []store.GameSummary {
	t.Helper()
	pg, err := s.ListGames(store.GameListOpts{Limit: n})
	if err != nil {
		t.Fatalf("ListGames: %v", err)
	}
	if len(pg.Games) < n {
		t.Fatalf("ListGames: got %d games, want >= %d (fixture corpus too small?)", len(pg.Games), n)
	}
	return pg.Games
}

// TestLibraryPageRendersCards: GET /library over the scanned fixture
// corpus renders the gallery — real titles from every system, the
// per-card system chip and verify pill, and art URLs pointing at /art.
func TestLibraryPageRendersCards(t *testing.T) {
	srv := newTestServer(t)

	rec := get(t, srv.Handler(), "/library")
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /library: status = %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	for _, marker := range []string{
		`class="gcard"`,                           // the card grid rendered at all
		"Starlit Vault (USA)",                     // nes title
		"Astral Almari (USA)",                     // snes title
		"Pocket Plumber (USA)",                    // gb title
		`<span class="chip">nes</span>`,           // system chip …
		`<span class="chip">gb</span>`,            // … for more than one system
		`data-system="nes" data-verify="unknown"`, // card carries its verify state
		`<span class="pill unknown" title="never verified">unknown</span>`, // per-game pill
		`src="/art/nes/`, // cover art wired to the art route
	} {
		if !strings.Contains(body, marker) {
			t.Errorf("GET /library: body missing marker %q", marker)
		}
	}
}

// TestLibrarySearchFiltersServerSide: ?q= filters in the store query —
// only the matching card renders, and nothing else leaks into the grid.
func TestLibrarySearchFiltersServerSide(t *testing.T) {
	srv := newTestServer(t)

	rec := get(t, srv.Handler(), "/library?q=Starlit")
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /library?q=Starlit: status = %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "Starlit Vault (USA)") {
		t.Error("search result missing the matching card")
	}
	if !strings.Contains(body, `matching “Starlit”`) {
		t.Error("search echo line missing")
	}
	for _, absent := range []string{"Astral Almari", "Pocket Plumber", "Mecha Garden"} {
		if strings.Contains(body, absent) {
			t.Errorf("non-matching title %q leaked past the server-side filter", absent)
		}
	}

	// A garbage/no-match query browses empty, not 500.
	if rec := get(t, srv.Handler(), "/library?q=zqxwvu"); rec.Code != http.StatusOK ||
		!strings.Contains(rec.Body.String(), "no games match.") {
		t.Errorf("GET /library?q=<nomatch>: status = %d, want 200 + empty-state", rec.Code)
	}
}

// TestLibraryPaginationControls: 13 fixture games at libPageSize=10 make
// exactly 2 pages; the pager links are plain /library URLs preserving the
// page param, and page 2 holds exactly the overflow rows.
func TestLibraryPaginationControls(t *testing.T) {
	srv := newTestServer(t)
	h := srv.Handler()

	p1 := get(t, h, "/library")
	if p1.Code != http.StatusOK {
		t.Fatalf("GET /library: status = %d, want 200", p1.Code)
	}
	body := p1.Body.String()
	if !strings.Contains(body, "page 1 of 2") || !strings.Contains(body, "13 games") {
		t.Error("pager must report 2 pages over the 13-game fixture corpus")
	}
	if !strings.Contains(body, `<a href="/library?page=2" rel="next">`) {
		t.Error("page 1 must carry a next link with the page param")
	}

	p2 := get(t, h, "/library?page=2")
	if p2.Code != http.StatusOK {
		t.Fatalf("GET /library?page=2: status = %d, want 200", p2.Code)
	}
	body2 := p2.Body.String()
	if !strings.Contains(body2, "page 2 of 2") {
		t.Error("page 2 must self-report")
	}
	if !strings.Contains(body2, `<a href="/library" rel="prev">`) {
		t.Error("page 2 must link back to page 1")
	}
	if !strings.Contains(body2, "Vault of Vertigo (USA)") { // sorts last → overflow row
		t.Error("page 2 missing the overflow title")
	}
	if strings.Contains(body2, "Astral Almari (USA)") { // sorts first → page 1 only
		t.Error("page 2 repeats a page-1 card")
	}
}

// TestGameDetail: an existing game renders its identity (title, rel_path,
// chips) plus the verify trail — the report link only once the system has
// an ingested report — and bogus ids read as absent (404), never 500.
func TestGameDetail(t *testing.T) {
	srv := newTestServer(t)
	h := srv.Handler()

	g := firstGames(t, srv.st, 1)[0]

	detail := func() string {
		rec := get(t, h, fmt.Sprintf("/systems/%s/games/%d", g.SystemKey, g.ID))
		if rec.Code != http.StatusOK {
			t.Fatalf("GET /systems/%s/games/%d: status = %d, want 200", g.SystemKey, g.ID, rec.Code)
		}
		return rec.Body.String()
	}

	body := detail()
	if !strings.Contains(body, "Astral Almari (USA)") || !strings.Contains(body, "Astral Almari (USA).sfc") {
		t.Error("detail page missing title / rel_path")
	}
	if !strings.Contains(body, `<span class="pill unknown" title="never verified">unknown</span>`) {
		t.Error("detail page missing the per-game verify pill")
	}
	if strings.Contains(body, "/verify/reports/") {
		t.Error("report link rendered although no report was ingested yet")
	}

	stamp := time.Now().UTC().Format(time.RFC3339)
	if err := srv.st.RecordVerifyResult(store.VerifyResult{
		SystemKey: g.SystemKey, FinishedAt: stamp, DatGames: 4, Found: 4,
		ReportPath: "/scratch/reports/" + g.SystemKey + ".csv",
	}); err != nil {
		t.Fatal(err)
	}
	if body = detail(); !strings.Contains(body, `href="/verify/reports/`+g.SystemKey+`.csv"`) {
		t.Error("detail page missing the igir report link after ingest")
	}

	for _, bogus := range []string{
		fmt.Sprintf("/systems/%s/games/999999", g.SystemKey), // well-formed but absent id
		"/systems/nes/games/not-a-number",                    // non-numeric id
	} {
		if rec := get(t, h, bogus); rec.Code != http.StatusNotFound {
			t.Errorf("GET %s = %d, want 404", bogus, rec.Code)
		}
	}
}

// TestArtDeterministic: the SVG poster is a pure function of its inputs —
// byte-identical across repeat requests (stable strong ETag depends on
// it), divergent across different titles.
func TestArtDeterministic(t *testing.T) {
	srv := newTestServer(t)
	h := srv.Handler()
	games := firstGames(t, srv.st, 2)
	artURL := func(g store.GameSummary) string {
		return fmt.Sprintf("/art/%s/%d", g.SystemKey, g.ID)
	}

	r1 := get(t, h, artURL(games[0]))
	r2 := get(t, h, artURL(games[0]))
	if r1.Code != http.StatusOK || r2.Code != http.StatusOK {
		t.Fatalf("GET art: statuses = %d/%d, want 200/200", r1.Code, r2.Code)
	}
	if ct := r1.Header().Get("Content-Type"); ct != "image/svg+xml" {
		t.Errorf("art Content-Type = %q, want image/svg+xml", ct)
	}
	if !bytes.Equal(r1.Body.Bytes(), r2.Body.Bytes()) {
		t.Error("same game served twice yielded different bytes — determinism broken")
	}

	other := get(t, h, artURL(games[1]))
	if bytes.Equal(r1.Body.Bytes(), other.Body.Bytes()) {
		t.Error("different titles produced identical poster bytes")
	}
	if !strings.HasPrefix(r1.Body.String(), "<svg ") {
		t.Errorf("art body is not SVG: %.40q", r1.Body.String())
	}
}

// TestArtRejectsTraversal: traversal-shaped path segments in either
// variable position never resolve to content. Encoded segments survive
// mux cleaning and reach the handler, which whitelists them (encoded
// slashes keep the segment non-numeric / non-system) → 400/404; a RAW
// dot-dot segment is cleaned by ServeMux before routing and redirects
// back into the route — nothing outside /art is reachable either way.
func TestArtRejectsTraversal(t *testing.T) {
	srv := newTestServer(t)
	h := srv.Handler()

	for _, path := range []string{
		"/art/..%2F..%2Fetc/7", // encoded .. in systemKey position
		"/art/nes/..%2F7",      // encoded .. in gameID position
	} {
		rec := get(t, h, path)
		if rec.Code != http.StatusBadRequest && rec.Code != http.StatusNotFound {
			t.Errorf("GET %s = %d, want 400/404", path, rec.Code)
		}
	}

	// Raw dot segments are rewritten by ServeMux BEFORE routing
	// (/art/../nes/7 → /nes/7 — the parent segment collapses too), so no
	// handler ever sees them. The redirect must stay same-origin and the
	// destination must not serve gallery content.
	raw := get(t, h, "/art/../nes/7")
	if raw.Code < 300 || raw.Code >= 400 {
		t.Errorf("GET /art/../nes/7 = %d, want a cleaning redirect (3xx)", raw.Code)
	}
	loc := raw.Header().Get("Location")
	if !strings.HasPrefix(loc, "/") || strings.HasPrefix(loc, "//") {
		t.Errorf("dot-segment cleanup redirect left the origin: %q", loc)
	}
	if followed := get(t, h, loc); followed.Code == http.StatusOK &&
		strings.Contains(followed.Body.String(), "<svg") {
		t.Errorf("cleaned traversal target %q served gallery content", loc)
	}
}

// TestArtFallsBackToSVG: with ARCADE_WEBAPP_ART_DIR unwired (empty —
// main.go only calls WithArt for a non-empty dir) every request gets the
// generated poster, never a scraped file.
func TestArtFallsBackToSVG(t *testing.T) {
	t.Setenv("ARCADE_WEBAPP_ART_DIR", "")
	srv := newTestServer(t) // no WithArt option → s.artDir stays ""

	g := firstGames(t, srv.st, 1)[0]
	rec := get(t, srv.Handler(), fmt.Sprintf("/art/%s/%d", g.SystemKey, g.ID))
	if rec.Code != http.StatusOK {
		t.Fatalf("GET art (unconfigured): status = %d, want 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "image/svg+xml" {
		t.Errorf("fallback Content-Type = %q, want image/svg+xml", ct)
	}
	title := gameTitle(g.RelPath)
	if !strings.Contains(rec.Body.String(), `aria-label="`+title+` cover art"`) {
		t.Errorf("fallback poster not derived from the title %q", title)
	}
}
