package web

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/generate"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// The P7 web suite: hide/show toggles, the bulk unhide, the hidden
// library filter, and the custom-collections CRUD UI — every mutation
// CSRF-gated and regeneration-triggering (async; tests poll for the run
// row rather than sleeping on internals).

func postHXForm(t *testing.T, h http.Handler, path string, vals url.Values) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest("POST", path, strings.NewReader(vals.Encode()))
	req.Header.Set("X-HX-Request", "true")
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

// waitGenerateRuns polls until at least want FINISHED kind=generate runs
// exist (the async trigger's durable record), or fails after a deadline.
func waitGenerateRuns(t *testing.T, srv *Server, want int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
		got, err := srv.st.RecentRuns(50)
		if err != nil {
			t.Fatal(err)
		}
		n := 0
		for _, r := range got {
			if r.Kind == "generate" && r.FinishedAt != "" {
				n++
			}
		}
		if n >= want {
			return
		}
	}
	t.Fatalf("only %d finished generate runs appeared within the deadline", countFinishedGenerateRuns(srv))
}

func countFinishedGenerateRuns(srv *Server) int {
	got, err := srv.st.RecentRuns(50)
	if err != nil {
		return 0
	}
	n := 0
	for _, r := range got {
		if r.Kind == "generate" && r.FinishedAt != "" {
			n++
		}
	}
	return n
}

// TestHideToggleEndpoint pins the P7 per-game curation action: CSRF gate,
// toggle semantics through ONE endpoint, the refreshed actions region
// with the flipped label, and one async launcher-DB regeneration per
// toggle.
func TestHideToggleEndpoint(t *testing.T) {
	h := newGenServer(t)
	handler := h.srv.Handler()
	games := firstGames(t, h.srv.st, 1)
	g := games[0]
	ep := fmt.Sprintf("/systems/%s/games/%d/hide", g.SystemKey, g.ID)

	// CSRF posture: every mutating endpoint is htmx-only (D-P2c).
	req := httptest.NewRequest("POST", ep, nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("POST %s without X-HX-Request = %d, want 403", ep, rec.Code)
	}

	// Unknown game id → 404, never a silent ok.
	if rec := postHX(t, handler, "/systems/"+g.SystemKey+"/games/999999/hide"); rec.Code != http.StatusNotFound {
		t.Fatalf("hide unknown game = %d, want 404", rec.Code)
	}

	// Hide: the response swaps #game-actions with the Show label.
	rec = postHX(t, handler, ep)
	if rec.Code != http.StatusOK {
		t.Fatalf("hide POST = %d, want 200", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), `id="game-actions"`) || !strings.Contains(rec.Body.String(), "Show</button>") {
		t.Fatalf("hide response must re-render the region with the flipped label:\n%s", rec.Body)
	}
	pg, _ := h.srv.st.ListGames(store.GameListOpts{SystemKey: g.SystemKey, Hidden: boolPtr(true)})
	if len(pg.Games) != 1 || pg.Games[0].ID != g.ID {
		t.Fatalf("hidden flag not persisted: %+v", pg.Games)
	}

	// Toggle back: same endpoint shows it again.
	rec = postHX(t, handler, ep)
	if !strings.Contains(rec.Body.String(), "Hide</button>") {
		t.Fatalf("toggle must flip the label back:\n%s", rec.Body)
	}
	pg, _ = h.srv.st.ListGames(store.GameListOpts{SystemKey: g.SystemKey, Hidden: boolPtr(true)})
	if len(pg.Games) != 0 {
		t.Fatalf("unhide did not clear the flag: %+v", pg.Games)
	}

	// Each toggle triggered one background regeneration (2 total).
	waitGenerateRuns(t, h.srv, 2)
}

func boolPtr(b bool) *bool { return &b }

// TestUnhideAllEndpoint pins the bulk action: CSRF gate, unknown system
// 404, the affordance rendered only where hidden>0, and the flip clears
// every flag of the system.
func TestUnhideAllEndpoint(t *testing.T) {
	h := newGenServer(t)
	handler := h.srv.Handler()

	// Hide two NES games directly (the endpoint under test is the bulk
	// unhide, not the single toggle; the fixture corpus spans systems, so
	// the system key is pinned explicitly).
	nesGames, _ := h.srv.st.ListGames(store.GameListOpts{SystemKey: "nes", Limit: 2})
	if len(nesGames.Games) != 2 {
		t.Fatalf("nes fixture games = %d, want 2", len(nesGames.Games))
	}
	for _, g := range nesGames.Games {
		if err := h.srv.st.SetGameHidden("nes", g.RelPath, true); err != nil {
			t.Fatal(err)
		}
	}

	// CSRF posture.
	req := httptest.NewRequest("POST", "/systems/nes/unhide-all", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("POST /systems/nes/unhide-all without header = %d, want 403", rec.Code)
	}
	if rec := postHX(t, handler, "/systems/nope/unhide-all"); rec.Code != http.StatusNotFound {
		t.Fatalf("unhide-all unknown system = %d, want 404", rec.Code)
	}

	// The verify worklist renders the affordance while hidden>0…
	frag := get(t, handler, "/partials/verify").Body.String()
	if !strings.Contains(frag, `hx-post="/systems/nes/unhide-all"`) {
		t.Fatal("verify fragment missing the unhide-all affordance")
	}
	// …and not for systems with nothing hidden.
	if strings.Contains(frag, `hx-post="/systems/snes/unhide-all"`) {
		t.Fatal("unhide-all rendered for a system with zero hidden games")
	}

	if rec := postHX(t, handler, "/systems/nes/unhide-all"); rec.Code != http.StatusOK {
		t.Fatalf("unhide-all = %d, want 200", rec.Code)
	}
	pg, _ := h.srv.st.ListGames(store.GameListOpts{SystemKey: "nes"})
	for _, g := range pg.Games {
		if g.Hidden {
			t.Fatalf("game still hidden after unhide-all: %+v", g)
		}
	}
	frag = get(t, handler, "/partials/verify").Body.String()
	if strings.Contains(frag, `hx-post="/systems/nes/unhide-all"`) {
		t.Fatal("affordance still rendered after everything was shown")
	}
	waitGenerateRuns(t, h.srv, 1)
}

// TestLibraryHiddenFilter pins ?hidden=1|0 server-side filtering and the
// filter select echoing its state.
func TestLibraryHiddenFilter(t *testing.T) {
	srv := newTestServer(t)
	handler := srv.Handler()

	games := firstGames(t, srv.st, 1)
	if err := srv.st.SetGameHidden(games[0].SystemKey, games[0].RelPath, true); err != nil {
		t.Fatal(err)
	}

	visibleOnly := get(t, handler, "/library?hidden=0").Body.String()
	hiddenOnly := get(t, handler, "/library?hidden=1").Body.String()
	title := gameTitle(games[0].RelPath)
	if !strings.Contains(hiddenOnly, title) || strings.Contains(visibleOnly, title) {
		t.Fatalf("hidden filter broken: %q present in hidden-only=%v visible-only=%v",
			title, strings.Contains(hiddenOnly, title), strings.Contains(visibleOnly, title))
	}
	// Totals move server-side (page 1 renders libPageSize cards; the
	// "N games" echo line is the honest count).
	if !strings.Contains(visibleOnly, "12 games") || !strings.Contains(hiddenOnly, "1 games") {
		t.Errorf("totals wrong: visible-only=%q hidden-only=%q", totalsOf(visibleOnly), totalsOf(hiddenOnly))
	}
	page := get(t, handler, "/library?hidden=1").Body.String()
	if !strings.Contains(page, `<option value="1" selected>hidden only</option>`) {
		t.Error("filter select does not echo hidden=1")
	}
}

// totalsOf extracts the pager's total-games echo for diagnostics.
func totalsOf(page string) string {
	for _, line := range strings.Split(page, "\n") {
		if strings.Contains(line, "games</span>") || strings.Contains(line, "of ") && strings.Contains(line, "games") {
			return strings.TrimSpace(line)
		}
	}
	return "(none)"
}

// TestCollectionsCRUDUI pins the P7 collections UI end to end: create,
// editor search excluding members, add/remove with identity params,
// rename keeping the shortname, delete, and the 404s.
func TestCollectionsCRUDUI(t *testing.T) {
	srv := newTestServer(t)
	handler := srv.Handler()

	// CSRF posture on the create route (the {id} routes need an id; their
	// gate is the same requireHX call asserted via delete below).
	req := httptest.NewRequest("POST", "/collections/create", nil)
	rec403 := httptest.NewRecorder()
	handler.ServeHTTP(rec403, req)
	if rec403.Code != http.StatusForbidden {
		t.Errorf("POST /collections/create without X-HX-Request = %d, want 403", rec403.Code)
	}

	// Create: empty name re-renders with an error, real name lands.
	rec := postHXForm(t, handler, "/collections/create", url.Values{"name": {""}})
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), "needs a name") {
		t.Fatalf("empty-name create = %d, want 200 + inline error:\n%s", rec.Code, rec.Body)
	}
	rec = postHXForm(t, handler, "/collections/create",
		url.Values{"name": {"Kitchen Quick-Play"}, "summary": {"pick up and play"}})
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), "Kitchen Quick-Play") ||
		!strings.Contains(rec.Body.String(), "kitchen-quick-play") {
		t.Fatalf("create did not land:\n%s", rec.Body)
	}
	cols, _ := srv.st.Collections()
	if len(cols) != 1 {
		t.Fatalf("collections = %d, want 1", len(cols))
	}
	cid := cols[0].ID

	// ADV-P7-01: a name deriving a catalogue identity is refused with a
	// 409 that NAMES the collision (main-collection shortname and
	// "-pending" section alike) — never a success-shaped response while
	// every future regeneration of that system would fail validation.
	rec = postHXForm(t, handler, "/collections/create", url.Values{"name": {"NES"}})
	if rec.Code != http.StatusConflict || !strings.Contains(rec.Body.String(), "identity &#34;nes&#34;") {
		t.Fatalf("create NES = %d, want 409 naming the nes collision:\n%s", rec.Code, rec.Body)
	}
	rec = postHXForm(t, handler, "/collections/create", url.Values{"name": {"NES Pending"}})
	if rec.Code != http.StatusConflict || !strings.Contains(rec.Body.String(), "nes-pending") {
		t.Fatalf("create 'NES Pending' = %d, want 409 naming the nes-pending collision:\n%s", rec.Code, rec.Body)
	}
	cols, _ = srv.st.Collections()
	if len(cols) != 1 {
		t.Fatalf("rejected creates left %d rows, want 1", len(cols))
	}

	// Editor page renders.
	editorURL := fmt.Sprintf("/collections/%d", cid)
	if rec := get(t, handler, editorURL); rec.Code != 200 {
		t.Fatalf("GET editor = %d, want 200", rec.Code)
	}

	// Search box finds candidates; existing members are excluded from the
	// candidate list (they render in the member table instead).
	games := firstGames(t, srv.st, 2)
	first, second := games[0], games[1]
	addURL := fmt.Sprintf("/collections/%d/add?system=%s&game=%d", cid, first.SystemKey, first.ID)
	rec = postHX(t, handler, addURL)
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), gameTitle(first.RelPath)) {
		t.Fatalf("add did not render the member table:\n%s", rec.Body)
	}

	secondAddURL := fmt.Sprintf("/collections/%d/add?system=%s&game=%d", cid, second.SystemKey, second.ID)
	searchPage := get(t, handler, editorURL+"?q="+url.QueryEscape(searchPrefix(second))).Body.String()
	if !strings.Contains(searchPage, secondAddURL) {
		t.Fatalf("search result missing the add affordance for the non-member:\n%s", searchPage)
	}

	// Add twice → still one membership (store idempotence via the UI).
	postHX(t, handler, addURL)
	members, _ := srv.st.CollectionMembers(cid)
	if len(members) != 1 {
		t.Fatalf("members = %d, want 1 (re-add must be idempotent)", len(members))
	}

	// Rename keeps the derived shortname stable.
	rec = postHXForm(t, handler, fmt.Sprintf("/collections/%d/update", cid),
		url.Values{"name": {"Late Night Set"}, "summary": {"after dark"}})
	if !strings.Contains(rec.Body.String(), "Late Night Set") || !strings.Contains(rec.Body.String(), "kitchen-quick-play") {
		t.Fatalf("rename mangled the collection:\n%s", rec.Body)
	}

	// ADV-P7-01: renaming onto a catalogue identity is refused like a
	// create (409 naming the collision), while free names still land.
	rec = postHXForm(t, handler, fmt.Sprintf("/collections/%d/update", cid),
		url.Values{"name": {"SNES"}})
	if rec.Code != http.StatusConflict || !strings.Contains(rec.Body.String(), "identity &#34;snes&#34;") {
		t.Fatalf("rename to SNES = %d, want 409 naming the snes collision:\n%s", rec.Code, rec.Body)
	}

	// Remove drops exactly the member.
	removeURL := fmt.Sprintf("/collections/%d/remove?system=%s&game=%d", cid, first.SystemKey, first.ID)
	if rec := postHX(t, handler, removeURL); rec.Code != 200 {
		t.Fatalf("remove = %d, want 200", rec.Code)
	}
	members, _ = srv.st.CollectionMembers(cid)
	if len(members) != 0 {
		t.Fatalf("members after remove = %d, want 0", len(members))
	}

	// Bad identity params → 400; unknown ids → 404.
	if rec := postHX(t, handler, fmt.Sprintf("/collections/%d/remove", cid)); rec.Code != 400 {
		t.Errorf("remove without params = %d, want 400", rec.Code)
	}
	if rec := get(t, handler, "/collections/999999"); rec.Code != 404 {
		t.Errorf("GET unknown editor = %d, want 404", rec.Code)
	}
	if rec := postHX(t, handler, "/collections/999999/delete"); rec.Code != 404 {
		t.Errorf("DELETE unknown = %d, want 404", rec.Code)
	}

	// Delete removes the row and the list panel refreshes.
	rec = postHX(t, handler, fmt.Sprintf("/collections/%d/delete", cid))
	if rec.Code != 200 || strings.Contains(rec.Body.String(), "Late Night Set") {
		t.Fatalf("delete did not clear the list panel:\n%s", rec.Body)
	}
	cols, _ = srv.st.Collections()
	if len(cols) != 0 {
		t.Fatalf("collections after delete = %d, want 0", len(cols))
	}
	// (Regeneration triggering is asserted on the generator-wired harness
	// in TestCollectionEditTriggersRegeneration; this harness wires none.)

	// Nav surfaces the page.
	if page := get(t, handler, "/collections"); !strings.Contains(page.Body.String(), `href="/collections" class="active"`) {
		t.Error("/collections nav item not marked active")
	}
}

// searchPrefix narrows a title to its first token so the FTS prefix match
// hits deterministically regardless of the rest of the filename.
func searchPrefix(g store.GameSummary) string {
	t := gameTitle(g.RelPath)
	if i := strings.IndexAny(t, " (-"); i > 0 {
		t = t[:i]
	}
	return t
}

// TestCollectionEditTriggersRegeneration: adding a member fires the async
// launcher-DB regeneration — the served file gains the custom block.
func TestCollectionEditTriggersRegeneration(t *testing.T) {
	h := newGenServer(t)
	handler := h.srv.Handler()

	cols, _ := h.srv.st.Collections() // none yet
	if len(cols) != 0 {
		t.Fatalf("fresh fixture has %d collections, want 0", len(cols))
	}
	if rec := postHXForm(t, handler, "/collections/create", url.Values{"name": {"Kitchen Quick-Play"}}); rec.Code != 200 {
		t.Fatal("create failed")
	}
	cols, _ = h.srv.st.Collections()
	cid := cols[0].ID

	games, _ := h.srv.st.ListGames(store.GameListOpts{SystemKey: "nes", Limit: 1})
	if len(games.Games) != 1 {
		t.Fatal("no nes fixture game found")
	}
	g := games.Games[0]
	if rec := postHX(t, handler, fmt.Sprintf("/collections/%d/add?system=%s&game=%d", cid, g.SystemKey, g.ID)); rec.Code != 200 {
		t.Fatal("add failed")
	}

	waitGenerateRuns(t, h.srv, 1)
	md := filepath.Join(h.root, "games", "cartridge", "nes", "metadata.pegasus.txt")
	b, err := os.ReadFile(md)
	if err != nil {
		t.Fatal(err)
	}
	out := string(b)
	for _, want := range []string{
		generate.CustomCollectionMarker,
		"collection: Kitchen Quick-Play",
		"shortname: kitchen-quick-play",
		`launch: jupiter-retroarch -L fceumm "{file.path}"`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("generated file missing %q after the collection edit:\n%s", want, out)
		}
	}
}
