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

// newTestServer builds the full template+handler stack over a scanned
// fixture tree — the render smoke test runs the real templates, not a
// reimplementation.
func newTestServer(t *testing.T) *Server {
	t.Helper()
	root := t.TempDir()
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
	h.ServeHTTP(rec, httptest.NewRequest("POST", "/rescan", nil))
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
