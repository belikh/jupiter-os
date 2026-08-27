package web

import (
	"net/http"
	"strings"
	"testing"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// TestLibraryMetadataFilters pins the UI half of "filter by any of the
// metadata": ?desc= / ?cover= / ?genre= filter the grid server-side, the
// selects render with the active choice selected, and the genre select
// lists exactly the store's distinct ingested genres. Seed data mirrors
// the fixture corpus titles so assertions can name cards.
func TestLibraryMetadataFilters(t *testing.T) {
	srv := newTestServer(t)
	h := srv.Handler()

	// Seed: Starlit Vault gets description+cover+genre; Astral Almari
	// gets description only; everything else stays plain.
	first := firstGames(t, srv.st, 13)
	var starlit, astral store.GameSummary
	for _, g := range first {
		switch {
		case strings.HasPrefix(g.RelPath, "Starlit Vault"):
			starlit = g
		case strings.HasPrefix(g.RelPath, "Astral Almari"):
			astral = g
		}
	}
	if starlit.ID == 0 || astral.ID == 0 {
		t.Fatalf("fixture corpus missing seed titles (starlit=%d astral=%d)", starlit.ID, astral.ID)
	}
	if err := srv.st.SetSystemScrapeFlags(starlit.SystemKey, []store.GameScrapeFlag{
		{RelPath: starlit.RelPath, Description: true, Cover: true},
	}); err != nil {
		t.Fatalf("SetSystemScrapeFlags: %v", err)
	}
	if err := srv.st.SetSystemScrapeFlags(astral.SystemKey, []store.GameScrapeFlag{
		{RelPath: astral.RelPath, Description: true},
	}); err != nil {
		t.Fatalf("SetSystemScrapeFlags (astral): %v", err)
	}
	if err := srv.st.SetGameMeta(starlit.SystemKey, []store.GameMeta{
		{RelPath: starlit.RelPath, Genre: "Platform"},
	}); err != nil {
		t.Fatalf("SetGameMeta: %v", err)
	}

	// desc=yes → both flagged games, nobody else.
	body := get(t, h, "/library?desc=yes").Body.String()
	if !strings.Contains(body, "Starlit Vault (USA)") || !strings.Contains(body, "Astral Almari (USA)") {
		t.Error("desc=yes must include both flagged games")
	}
	if strings.Contains(body, "Pocket Plumber (USA)") {
		t.Error("desc=yes leaked an unflagged game")
	}
	if !strings.Contains(body, `<option value="yes" selected>has description</option>`) {
		t.Error("desc select must reflect the active yes choice")
	}

	// desc=yes + cover=yes → AND semantics: only Starlit.
	body = get(t, h, "/library?desc=yes&cover=yes").Body.String()
	if !strings.Contains(body, "Starlit Vault (USA)") {
		t.Error("desc+cover=yes must include Starlit")
	}
	if strings.Contains(body, "Astral Almari (USA)") {
		t.Error("desc+cover=yes leaked a desc-only game (filters must AND)")
	}

	// cover=no → everything except Starlit.
	body = get(t, h, "/library?cover=no").Body.String()
	if strings.Contains(body, "Starlit Vault (USA)") || !strings.Contains(body, "Pocket Plumber (USA)") {
		t.Error("cover=no must exclude the covered game only")
	}

	// genre filter: exact match, select carries the store's genre list.
	body = get(t, h, "/library?genre=Platform").Body.String()
	if !strings.Contains(body, "Starlit Vault (USA)") {
		t.Error("genre=Platform must include the seeded game")
	}
	if strings.Contains(body, "Astral Almari (USA)") {
		t.Error("genre=Platform leaked an untagged game")
	}
	if !strings.Contains(body, `<option value="Platform" selected>Platform</option>`) {
		t.Error("genre select must reflect the active choice")
	}
	if !strings.Contains(body, `aria-label="genre filter"`) || !strings.Contains(body, `>Platform</option>`) {
		t.Error("genre select options missing")
	}

	// Garbage param values degrade to "any" (browse, never 500).
	if rec := get(t, h, "/library?desc=maybe&cover=sometimes&genre="); rec.Code != http.StatusOK {
		t.Errorf("garbage filter params: status = %d, want 200", rec.Code)
	}

	// Pager preserves the active filters (cover=no leaves 12 of 13 → 2 pages).
	body = get(t, h, "/library?cover=no&page=1").Body.String()
	if !strings.Contains(body, `cover=no`) || !strings.Contains(body, "page=2") {
		t.Error("pager links must carry the active filters to page 2")
	}
}
