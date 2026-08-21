package web

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/fixture"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/scanner"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// fixtureScan writes the fixture corpus (ROMs, DATs, cache, catalogue
// TSV) under root and returns a scanned store + scanner. Both the plain
// dashboard server and the downloads server build on it.
func fixtureScan(t *testing.T, root string) (*store.Store, *scanner.Scanner) {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "arcade.db")

	if err := fixture.WriteROMs(filepath.Join(root, "games", "cartridge")); err != nil {
		t.Fatal(err)
	}
	if err := fixture.WriteDATs(filepath.Join(root, "metadata", "no-intro-dats")); err != nil {
		t.Fatal(err)
	}
	// nes: 3 of 5 games cached.
	nesCache := filepath.Join(root, "metadata", "skyscraper-cache", "nes")
	if err := os.MkdirAll(nesCache, 0o755); err != nil {
		t.Fatal(err)
	}
	dbXML := `<db>
  <resource id="a1" type="description" source="s">A</resource>
  <resource id="a2" type="description" source="s">B</resource>
  <resource id="a3" type="cover" source="s">covers/c.png</resource>
</db>`
	if err := os.WriteFile(filepath.Join(nesCache, "db.xml"), []byte(dbXML), 0o644); err != nil {
		t.Fatal(err)
	}
	tsv := "nes\tNintendo Entertainment System\tfceumm\t-\tnes\t-\tcartridge\tT.torrent\n" +
		"snes\tSuper Nintendo Entertainment System\tsnes9x\t-\tsfc,smc\t-\tcartridge\tT2.torrent\n" +
		"gb\tNintendo Game Boy\tgambatte\t-\tgb\t-\tcartridge\t-\n"
	if err := os.WriteFile(filepath.Join(root, "cartridge-catalogue.tsv"), []byte(tsv), 0o644); err != nil {
		t.Fatal(err)
	}

	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() }) //nolint:errcheck // test

	cfg := scanner.Config{
		CatalogueTsv:       filepath.Join(root, "cartridge-catalogue.tsv"),
		CartridgeRoot:      filepath.Join(root, "games", "cartridge"),
		OpticalRoot:        filepath.Join(root, "games", "optical"),
		ModernRoot:         filepath.Join(root, "games", "modern"),
		DATDir:             filepath.Join(root, "metadata", "no-intro-dats"),
		SkyscraperCacheDir: filepath.Join(root, "metadata", "skyscraper-cache"),
		IncomingDir:        filepath.Join(root, "cache", "incoming"),
		InventoryFile:      filepath.Join(root, "state", "inventory.json"),
		DBPath:             dbPath,
	}
	scan := scanner.New(cfg, st)
	if _, err := scan.Scan(); err != nil {
		t.Fatalf("fixture scan: %v", err)
	}
	return st, scan
}

// newTestServer builds the full template+handler stack over a scanned
// fixture tree — the render smoke test runs the real templates, not a
// reimplementation.
func newTestServer(t *testing.T) *Server {
	t.Helper()
	root := t.TempDir()
	st, scan := fixtureScan(t, root)
	srv, err := New(st, scan)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return srv
}

func get(t *testing.T, h http.Handler, path string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", path, nil))
	return rec
}

func TestDashboardRendersFixtureCards(t *testing.T) {
	srv := newTestServer(t)
	rec := get(t, srv.Handler(), "/")

	if rec.Code != 200 {
		t.Fatalf("GET /: status = %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	for _, marker := range []string{
		"jupiterOS",
		"pipeline dashboard",
		`data-system="nes" data-games="5" data-coverage="60"`,
		`data-system="snes" data-games="4"`,
		`data-system="gb" data-games="4" data-coverage="0"`,
		"Nintendo Entertainment System",
		"2026-08-21",      // fixture DAT date on the card
		">unknown</span>", // verify state: unknown until P3
		`id="status-panel"`,
		`id="system-cards"`,
		`hx-trigger="every 10s"`, // htmx polling on both fragments
		`hx-post="/rescan"`,      // rescan button
		// P1-critic a11y carry (landed with P2): meters are real
		// progressbars, polled regions are announced. (Unit fixture
		// coverages: nes 60%, snes/gb 0% — snes's 100% is the VM
		// fixture's assertion.)
		`role="progressbar"`,
		`aria-valuenow="60"`, // nes coverage meter
		`aria-valuenow="0"`,  // gb — 0% still carries a value
		`aria-live="polite"`,
		// The download stage now has a dashboard surface (P1 critic's
		// named gap): its summary fragment hook.
		`id="downloads-summary"`,
		`hx-get="/partials/downloads-summary"`,
	} {
		if !strings.Contains(body, marker) {
			t.Errorf("GET /: body missing marker %q", marker)
		}
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "text/html") {
		t.Errorf("GET /: Content-Type = %q, want text/html", ct)
	}
}

func TestDashboardEmptySystemCollapsed(t *testing.T) {
	srv := newTestServer(t)
	body := get(t, srv.Handler(), "/").Body.String()
	// All three fixture systems are active; the collapse line only appears
	// with empty systems. Assert the footer's absence shape indirectly: no
	// "catalogue system" summary line.
	if strings.Contains(body, "catalogue system") {
		t.Error("empty-systems footer rendered although no empty systems exist")
	}
}

func TestPartialSystemsIsFragment(t *testing.T) {
	srv := newTestServer(t)
	rec := get(t, srv.Handler(), "/partials/systems")

	if rec.Code != 200 {
		t.Fatalf("GET /partials/systems: status = %d", rec.Code)
	}
	body := rec.Body.String()
	if strings.Contains(body, "<html") {
		t.Error("fragment must not render the page layout")
	}
	if !strings.Contains(body, `id="system-cards"`) || !strings.Contains(body, `data-system="nes"`) {
		t.Error("fragment missing card wall content")
	}
}

func TestPartialStatusIsFragment(t *testing.T) {
	srv := newTestServer(t)
	rec := get(t, srv.Handler(), "/partials/status")

	if rec.Code != 200 {
		t.Fatalf("GET /partials/status: status = %d", rec.Code)
	}
	body := rec.Body.String()
	if strings.Contains(body, "<html") {
		t.Error("fragment must not render the page layout")
	}
	for _, marker := range []string{`id="status-panel"`, "Recent runs", "scan"} {
		if !strings.Contains(body, marker) {
			t.Errorf("status fragment missing marker %q", marker)
		}
	}
}

func TestRescanKicksScan(t *testing.T) {
	srv := newTestServer(t)
	h := srv.Handler()

	rec := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/rescan", nil)
	req.Header.Set("X-HX-Request", "true") // mutating endpoints are htmx-only (CSRF posture)
	h.ServeHTTP(rec, req)
	if rec.Code != 202 {
		t.Fatalf("POST /rescan: status = %d, want 202", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), `id="status-panel"`) {
		t.Error("POST /rescan must answer with the status fragment")
	}

	// The background scan finishes eventually; the runs table records it.
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		runs, err := srv.st.RecentRuns(2)
		if err != nil {
			t.Fatal(err)
		}
		if len(runs) >= 2 { // startup scan + rescan
			if runs[0].Status == "ok" && runs[0].Kind == "scan" {
				return
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("rescan did not record a second scan run within 10s")
}

func TestStaticAssetsServed(t *testing.T) {
	srv := newTestServer(t)

	js := get(t, srv.Handler(), "/static/htmx.min.js")
	if js.Code != 200 {
		t.Fatalf("GET /static/htmx.min.js: status = %d", js.Code)
	}
	if !strings.Contains(js.Body.String(), "htmx 2.0.10") {
		t.Error("vendored htmx missing its version banner comment")
	}
	if ct := js.Header().Get("Content-Type"); !strings.Contains(ct, "javascript") {
		t.Errorf("htmx Content-Type = %q", ct)
	}

	lic := get(t, srv.Handler(), "/static/htmx-LICENSE")
	if lic.Code != 200 || !strings.Contains(lic.Body.String(), "Zero-Clause BSD") {
		t.Errorf("htmx LICENSE served = %d, license text missing", lic.Code)
	}

	css := get(t, srv.Handler(), "/static/app.css")
	if css.Code != 200 || !strings.Contains(css.Body.String(), "--mauve") {
		t.Errorf("app.css served = %d, Catppuccin tokens missing", css.Code)
	}
}

func TestHealthz(t *testing.T) {
	srv := newTestServer(t)
	rec := get(t, srv.Handler(), "/healthz")

	if rec.Code != 200 {
		t.Fatalf("GET /healthz: status = %d", rec.Code)
	}
	body, err := io.ReadAll(rec.Body)
	if err != nil {
		t.Fatalf("reading body: %v", err)
	}
	if strings.TrimSpace(string(body)) != "ok" {
		t.Errorf("GET /healthz: body = %q, want %q", body, "ok")
	}
}

func TestUnknownPathIsNotFound(t *testing.T) {
	srv := newTestServer(t)
	if rec := get(t, srv.Handler(), "/no-such-page"); rec.Code != 404 {
		t.Fatalf("GET /no-such-page: status = %d, want 404", rec.Code)
	}
}

func TestHumanBytes(t *testing.T) {
	cases := map[int64]string{
		0:           "0 B",
		512:         "512 B",
		1024:        "1.0 KiB",
		1536:        "1.5 KiB",
		1024 * 1024: "1.0 MiB",
		3 << 30:     "3.0 GiB",
	}
	for in, want := range cases {
		if got := HumanBytes(in); got != want {
			t.Errorf("HumanBytes(%d) = %q, want %q", in, got, want)
		}
	}
}

// ADV-P1-05: a scan that finished ok but recorded warnings must surface in
// the health chip (not silently "healthy"), and the recent-runs detail
// cell must render human lines, not raw JSON.
func TestHealthChipAndDetailShowWarnings(t *testing.T) {
	srv := newTestServer(t)

	// Inject a finished run with one warning — newer than the scan run the
	// fixture server already recorded.
	id, err := srv.st.StartRun("scan")
	if err != nil {
		t.Fatal(err)
	}
	detail := `{"Systems":61,"Games":13,"Bytes":2236435,"IncomingFiles":0,"IncomingBytes":0,"Errors":0,"Warnings":["nes: ROM walk failed, kept previous rows: permission denied"]}`
	if err := srv.st.FinishRun(id, "ok", detail); err != nil {
		t.Fatal(err)
	}

	body := get(t, srv.Handler(), "/").Body.String()
	if !strings.Contains(body, `>1 warning<`) {
		t.Error("health chip does not show '1 warning' — warnings are invisible")
	}
	if strings.Contains(body, `<span class="pill ok">healthy</span>`) {
		t.Error("health chip says 'healthy' despite a warned run")
	}
	// The detail cell renders the warning line, not the JSON envelope.
	if !strings.Contains(body, "nes: ROM walk failed, kept previous rows: permission denied") {
		t.Error("runs table does not surface the warning text")
	}
	if strings.Contains(body, `{"Systems":61`) {
		t.Error("runs table still dumps raw JSON detail")
	}
}

// ADV-P1-05: a clean run's detail cell summarizes (systems/games/bytes),
// and a non-JSON detail (legacy/error rows) renders escaped+truncated.
func TestRunDetailHelper(t *testing.T) {
	clean := runDetail(store.Run{Kind: "scan", Status: "ok", Detail: `{"Systems":61,"Games":13,"Bytes":2236435,"Warnings":null}`})
	if s := string(clean); !strings.Contains(s, "61 systems") || !strings.Contains(s, "13 games") {
		t.Errorf("runDetail(clean) = %q, want systems/games summary", s)
	}
	warned := runDetail(store.Run{Kind: "scan", Status: "ok", Detail: `{"Systems":3,"Games":4,"Bytes":10,"Warnings":["boom","sizzle"]}`})
	if s := string(warned); !strings.Contains(s, "boom") || !strings.Contains(s, "sizzle") {
		t.Errorf("runDetail(warned) = %q, want both warning lines", s)
	}
	legacy := runDetail(store.Run{Kind: "verify", Status: "error", Detail: "igir exited 2: disk full & <gone>"})
	if s := string(legacy); !strings.Contains(s, "disk full") || strings.Contains(s, "<gone>") {
		t.Errorf("runDetail(non-JSON) = %q, want escaped text", s)
	}
}
