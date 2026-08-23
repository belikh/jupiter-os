package web

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/fixture"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/scrape"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// The P5 metadata-engine suite mirrors newVerifyServer's shape: fixture
// store + a REAL scrape.Driver over a fake Skyscraper binary (argv-
// recording test double; the VM test exercises a stubbed binary
// end-to-end). The fake copies a canned db.xml — keyed by the REAL
// fixture ROM sha1s, so ApplyCacheFlags' coverage math runs for real —
// into every cache dir it is handed for the nes platform.

// fakeSkyscraperP5 records argv to $FAKE_OUT (scrape_test's format),
// waits for $FAKE_GATE when set (serialization tests hold the batch open
// deterministically), then installs $FAKE_DBXML as the nes platform's
// db.xml. No network, no external tools.
const fakeSkyscraperP5 = `#!/bin/sh
{
  echo '---'
  for a in "$@"; do
    printf '%s\n' "$a"
  done
} >> "$FAKE_OUT"
if [ -n "${FAKE_GATE:-}" ]; then
  i=0
  while [ ! -f "$FAKE_GATE" ] && [ "$i" -lt 300 ]; do
    sleep 0.1
    i=$((i + 1))
  done
fi
p=""; d=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) p="$2" ;;
    -d) d="$2" ;;
  esac
  shift
done
if [ "$p" = "nes" ] && [ -n "$FAKE_DBXML" ]; then
  cp "$FAKE_DBXML" "$d/db.xml"
fi
`

// cannedNesDBXML renders a db.xml covering EVERY fixture nes game with
// description AND cover resources keyed by the real SHA1 cache ids —
// after one scrape nes must read 100%/100%.
func cannedNesDBXML(t *testing.T) string {
	t.Helper()
	var b strings.Builder
	b.WriteString("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<db>\n")
	for _, g := range fixture.Systems()[0].Games {
		h := fixture.Checksums(fixture.RomBytes(fixture.RomKey(fixture.Systems()[0], g), g.Size))
		fmt.Fprintf(&b, "  <resource id=%q type=\"description\" source=\"stub\" timestamp=\"1\">%s</resource>\n", h.SHA1, g.Name)
		fmt.Fprintf(&b, "  <resource id=%q type=\"cover\" source=\"stub\" timestamp=\"1\">covers/%s.png</resource>\n", h.SHA1, g.Name)
	}
	b.WriteString("</db>\n")
	return b.String()
}

type metaHarness struct {
	srv      *Server
	root     string
	argvPath string // $FAKE_OUT
	gatePath string // $FAKE_GATE (not created — the gate stays shut)
}

func newMetaServer(t *testing.T) metaHarness {
	t.Helper()
	root := t.TempDir()
	st, scan := fixtureScan(t, root)

	fake := filepath.Join(root, "fake-skyscraper")
	if err := os.WriteFile(fake, []byte(fakeSkyscraperP5), 0o755); err != nil {
		t.Fatal(err)
	}
	dbxml := filepath.Join(root, "canned-nes-db.xml")
	if err := os.WriteFile(dbxml, []byte(cannedNesDBXML(t)), 0o644); err != nil {
		t.Fatal(err)
	}
	argvPath := filepath.Join(root, "argv.txt")
	gatePath := filepath.Join(root, "gate")
	t.Setenv("FAKE_OUT", argvPath)
	t.Setenv("FAKE_DBXML", dbxml)
	t.Setenv("FAKE_GATE", "") // gate shut OFF; holdGate() arms it per-test

	driver := &scrape.Driver{
		BinPath:       fake,
		CacheDir:      filepath.Join(root, "metadata", "skyscraper-cache"),
		Store:         st,
		CartridgeRoot: filepath.Join(root, "games", "cartridge"),
		OpticalRoot:   filepath.Join(root, "games", "optical"),
		ModernRoot:    filepath.Join(root, "games", "modern"),
	}
	if !driver.Configured() {
		t.Fatal("harness driver not configured")
	}
	srv, err := New(st, scan, WithScrape(driver))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return metaHarness{srv: srv, root: root, argvPath: argvPath, gatePath: gatePath}
}

// waitScrapeSettled polls until the driver leaves Running and the store
// holds at least wantRuns finished kind=scrape rows.
func waitScrapeSettled(t *testing.T, h metaHarness, wantRuns int) []store.Run {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		st := h.srv.sc.State()
		runs, err := h.srv.st.RecentRuns(lastAttemptScanRuns)
		if err != nil {
			t.Fatal(err)
		}
		n := 0
		for _, r := range runs {
			if r.Kind == "scrape" && r.FinishedAt != "" {
				n++
			}
		}
		if !st.Running && n >= wantRuns {
			return runs
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("scrape never settled")
	return nil
}

func TestMetadataPageRendersWorklist(t *testing.T) {
	h := newMetaServer(t)

	rec := get(t, h.srv.Handler(), "/metadata")
	if rec.Code != 200 {
		t.Fatalf("GET /metadata: status = %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	for _, marker := range []string{
		`id="metadata-panel"`,
		`data-scrape="ok"`,
		`hx-post="/metadata/scrape"`,    // scrape-all action
		`hx-post="/systems/nes/scrape"`, // per-system scrape
		`Scrape all`,
		`aria-current="page">Metadata</a>`, // nav active state
		// Pre-scrape truth: nothing flagged yet, never scraped.
		`data-system="nes" data-games="5" data-desc-pct="0" data-cover-pct="0"`,
		`>never</span>`,
	} {
		if !strings.Contains(body, marker) {
			t.Errorf("GET /metadata: body missing marker %q", marker)
		}
	}
	// Idle page: no 3s poll (the trigger only renders while running).
	if strings.Contains(body, `hx-trigger="every 3s"`) {
		t.Error("idle metadata panel must not carry the 3s poll trigger")
	}

	frag := get(t, h.srv.Handler(), "/partials/metadata")
	if frag.Code != 200 {
		t.Fatalf("GET /partials/metadata: status = %d", frag.Code)
	}
	if strings.Contains(frag.Body.String(), "<html") {
		t.Error("metadata partial rendered the full layout")
	}
}

func TestMetadataNotConfiguredRendersStateAnd503s(t *testing.T) {
	srv := newTestServer(t) // no WithScrape

	body := get(t, srv.Handler(), "/metadata").Body.String()
	for _, marker := range []string{`data-scrape="unconfigured"`, "Skyscraper not configured"} {
		if !strings.Contains(body, marker) {
			t.Errorf("unconfigured /metadata missing %q", marker)
		}
	}
	for _, path := range []string{"/metadata/scrape", "/systems/nes/scrape"} {
		if rec := postHX(t, srv.Handler(), path); rec.Code != http.StatusServiceUnavailable {
			t.Errorf("POST %s unconfigured = %d, want 503", path, rec.Code)
		}
	}
}

// TestScrapeEndpointsRequireHTMXHeader carries D-P2c to the P5 routes.
func TestScrapeEndpointsRequireHTMXHeader(t *testing.T) {
	h := newMetaServer(t)
	gid := firstGameID(t, h.srv, "nes")
	for _, path := range []string{"/metadata/scrape", "/systems/nes/scrape",
		fmt.Sprintf("/systems/nes/games/%d/scrape", gid)} {
		req := httptest.NewRequest("POST", path, nil)
		rec := httptest.NewRecorder()
		h.srv.Handler().ServeHTTP(rec, req)
		if rec.Code != http.StatusForbidden {
			t.Errorf("POST %s without X-HX-Request = %d, want 403", path, rec.Code)
		}
	}
}

// TestScrapeAllSurfacesBusyAs409 is the serialization proof: the slot
// claim happens IN the request, so while a gated batch holds the driver,
// a second scrape-all AND a per-system submit both answer 409 Conflict
// deterministically (no goroutine race to hope against).
func TestScrapeAllSurfacesBusyAs409(t *testing.T) {
	h := newMetaServer(t)
	handler := h.srv.Handler()

	// Arm the gate: every fake invocation now blocks until it exists,
	// holding the batch open while the 409s are asserted.
	t.Setenv("FAKE_GATE", h.gatePath)
	if rec := postHX(t, handler, "/metadata/scrape"); rec.Code != http.StatusAccepted {
		t.Fatalf("POST /metadata/scrape: status = %d, want 202", rec.Code)
	}
	if got := postHX(t, handler, "/metadata/scrape").Code; got != http.StatusConflict {
		t.Errorf("second POST /metadata/scrape = %d, want 409", got)
	}
	if got := postHX(t, handler, "/systems/snes/scrape").Code; got != http.StatusConflict {
		t.Errorf("per-system POST while busy = %d, want 409", got)
	}

	// Release the gate; the batch finishes and the slot frees.
	if err := os.WriteFile(h.gatePath, []byte("go"), 0o644); err != nil {
		t.Fatal(err)
	}
	waitScrapeSettled(t, h, 1)
	if st := h.srv.sc.State(); st.Running {
		t.Error("driver still Running after the batch finished")
	}

	// Free again: the next submit is accepted (the rejection was the
	// serialization guard working, not a wedge).
	if rec := postHX(t, handler, "/systems/nes/scrape"); rec.Code != http.StatusAccepted {
		t.Errorf("POST /systems/nes/scrape after release = %d, want 202", rec.Code)
	}
	waitScrapeSettled(t, h, 2)

	runs, err := h.srv.st.RecentRuns(10)
	if err != nil {
		t.Fatal(err)
	}
	if runs[0].Kind != "scrape" || runs[0].Status != "ok" {
		t.Errorf("newest run = %s/%s, want scrape/ok", runs[0].Kind, runs[0].Status)
	}
}

// TestScrapeUpdatesCoverageInUI drives the whole loop with an ungated
// fake: POST → run row → db.xml installed → ApplyCacheFlags flips game
// flags → the fragment's percentages move 0→100.
func TestScrapeUpdatesCoverageInUI(t *testing.T) {
	h := newMetaServer(t)

	if rec := postHX(t, h.srv.Handler(), "/metadata/scrape"); rec.Code != http.StatusAccepted {
		t.Fatalf("POST /metadata/scrape: status = %d, want 202", rec.Code)
	}
	waitScrapeSettled(t, h, 1)

	ok := false
	for i := 0; i < 100; i++ {
		body := get(t, h.srv.Handler(), "/partials/metadata").Body.String()
		if strings.Contains(body, `data-system="nes" data-games="5" data-desc-pct="100" data-cover-pct="100"`) {
			ok = true
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !ok {
		t.Error("nes row never reached desc-pct=100/cover-pct=100 after the scrape")
	}

	// The audit trail: one scrape run whose detail names the systems with
	// outcomes and coverage counts (never raw JSON in the UI).
	runs, err := h.srv.st.RecentRuns(5)
	if err != nil {
		t.Fatal(err)
	}
	var detail struct {
		Systems []store.ScrapeOutcome `json:"Systems"`
	}
	if err := json.Unmarshal([]byte(runs[0].Detail), &detail); err != nil {
		t.Fatalf("scrape run detail unparsable: %v", err)
	}
	bySys := map[string]store.ScrapeOutcome{}
	for _, oc := range detail.Systems {
		bySys[oc.Sys] = oc
	}
	nes := bySys["nes"]
	if nes.Outcome != scrape.OutcomeScraped || nes.Desc != 5 || nes.Cover != 5 {
		t.Errorf("nes outcome = %+v, want scraped desc=5 cover=5", nes)
	}
	if oc := bySys["gb"]; oc.Outcome != scrape.OutcomeScraped {
		t.Errorf("gb outcome = %+v, want scraped (its tree has ROMs)", oc)
	}
}

// TestScrapeEmptySystemFilteredFromBatch proves StartAll filters to
// systems WITH ROM files: segacd-like empty catalogue keys never join.
func TestScrapeEmptySystemFilteredFromBatch(t *testing.T) {
	h := newMetaServer(t)
	if err := h.srv.sc.StartOne("snes"); err != nil {
		t.Fatalf("StartOne snes: %v", err)
	}
	waitScrapeSettled(t, h, 1)
	runs, _ := h.srv.st.RecentRuns(5)
	var detail struct {
		Systems []store.ScrapeOutcome `json:"Systems"`
	}
	if err := json.Unmarshal([]byte(runs[0].Detail), &detail); err != nil {
		t.Fatal(err)
	}
	if len(detail.Systems) != 1 || detail.Systems[0].Sys != "snes" {
		t.Errorf("batch ran %+v, want exactly [snes]", detail.Systems)
	}
}

func TestScrapeUnknownSystemIs404(t *testing.T) {
	h := newMetaServer(t)
	if got := postHX(t, h.srv.Handler(), "/systems/nope/scrape").Code; got != http.StatusNotFound {
		t.Errorf("POST /systems/nope/scrape = %d, want 404", got)
	}
}

// TestGameScrapeWiredToDriver covers the game-detail re-scrape hook:
// 202 + swapped actions region, argv windowed to the ONE ROM, 404s on
// bad ids.
func TestGameScrapeWiredToDriver(t *testing.T) {
	h := newMetaServer(t)
	gid := firstGameID(t, h.srv, "nes")
	rel := gameRelPath(t, h.srv, "nes", gid)

	rec := postHX(t, h.srv.Handler(), fmt.Sprintf("/systems/nes/games/%d/scrape", gid))
	if rec.Code != http.StatusAccepted {
		t.Fatalf("game scrape POST = %d, want 202", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), `id="game-actions"`) ||
		!strings.Contains(rec.Body.String(), `hx-post="/systems/nes/games/`) {
		t.Error("game scrape response did not swap the actions region")
	}
	waitScrapeSettled(t, h, 1)

	b, err := os.ReadFile(h.argvPath)
	if err != nil {
		t.Fatal(err)
	}
	invocations := strings.Count(string(b), "---")
	if invocations == 0 {
		t.Fatal("fake Skyscraper was never invoked")
	}
	// The gather pass(es) windowed (--startat/--endat at the rel_path);
	// the compose pass exports the whole platform (no window flags).
	// No ScreenScraper creds in this harness, so exactly ONE gather pass
	// runs (thegamesdb) — one --startat pair, never a third.
	if n := strings.Count(string(b), "--startat"); n != 1 {
		t.Errorf("--startat count = %d, want 1 (one gather pass, windowed)", n)
	}
	if !strings.Contains(string(b), "--endat") || !strings.Contains(string(b), rel) {
		t.Errorf("gather pass not windowed to %q, argv log:\n%s", rel, b)
	}

	if got := postHX(t, h.srv.Handler(), "/systems/nes/games/99999/scrape").Code; got != http.StatusNotFound {
		t.Errorf("unknown game id = %d, want 404", got)
	}
	if got := postHX(t, h.srv.Handler(), "/systems/nope/games/"+fmt.Sprint(gid)+"/scrape").Code; got != http.StatusNotFound {
		t.Errorf("wrong-system id = %d, want 404 (identity includes system)", got)
	}
}

// TestMetadataRunHistoryDeltas seeds two scrape runs and asserts the
// drill-down renders both points with the Δ-covered line.
func TestMetadataRunHistoryDeltas(t *testing.T) {
	h := newMetaServer(t)
	for i := 0; i < 2; i++ {
		if err := h.srv.sc.StartOne("nes"); err != nil {
			t.Fatalf("run %d: %v", i, err)
		}
		waitScrapeSettled(t, h, i+1)
	}

	body := get(t, h.srv.Handler(), "/partials/metadata").Body.String()
	if !strings.Contains(body, "run history (2)") {
		t.Error("drill-down missing the two recorded points")
	}
	// html/template escapes "+" as &#43; in text nodes — the delta is
	// rendered "(Δ&#43;0 covered)" for two identical runs.
	if !strings.Contains(body, "(Δ&#43;0 covered)") {
		t.Error("delta line missing from the history block")
	}
	if !strings.Contains(body, `>scraped</span>`) {
		t.Error("last-scrape outcome pill missing")
	}
}

// firstGameID returns any game id for the system (ids are autoincrement;
// tests never assume concrete values).
func firstGameID(t *testing.T, srv *Server, sys string) int64 {
	t.Helper()
	page, err := srv.st.ListGames(store.GameListOpts{SystemKey: sys, Limit: 1})
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Games) == 0 {
		t.Fatalf("no games for %s", sys)
	}
	return page.Games[0].ID
}

// gameRelPath resolves one game row's rel_path by (system, id) — the
// same identity the scrape route uses.
func gameRelPath(t *testing.T, srv *Server, sys string, id int64) string {
	t.Helper()
	g, err := srv.st.GetGame(sys, id)
	if err != nil || g == nil {
		t.Fatalf("GetGame(%s,%d): %v", sys, id, err)
	}
	return g.RelPath
}

// TestScrapeRunDetailEscapes proves the kind=scrape detail cell renders
// human lines (escaped, capped) rather than raw JSON.
func TestScrapeRunDetailEscapes(t *testing.T) {
	detail := `{"Systems":[{"Sys":"nes","Outcome":"scraped","Desc":5,"Cover":5},{"Sys":"gb","Outcome":"failed","Err":"all 2 pass(es) failed: <boom> & gone"}]}`
	html, ok := scrapeRunDetailHTML(detail)
	if !ok {
		t.Fatal("parseable scrape detail claimed no rendering")
	}
	if s := string(html); !strings.Contains(s, "nes: scraped") || !strings.Contains(s, "desc=5 cover=5") {
		t.Errorf("detail cell = %q, want outcome lines", s)
	}
	if strings.Contains(string(html), "<boom>") || strings.Contains(string(html), "& gone") {
		t.Errorf("detail cell not escaped: %q", html)
	}
	if _, ok := scrapeRunDetailHTML("not json"); ok {
		t.Error("non-JSON detail claimed a scrape rendering")
	}
}
