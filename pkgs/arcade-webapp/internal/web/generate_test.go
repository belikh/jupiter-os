package web

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/generate"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/igir"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/pipeline"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// The P6 web suite: the manual Regenerate endpoint + generation log +
// the post-verify trigger. Harness mirrors newMetaServer but wires the
// generator instead of the scrape driver.

type genHarness struct {
	srv  *Server
	root string
	gen  *generate.Generator
}

func newGenServer(t *testing.T) genHarness {
	t.Helper()
	root := t.TempDir()
	st, scan := fixtureScan(t, root)
	gen := &generate.Generator{
		St:            st,
		CartridgeRoot: filepath.Join(root, "games", "cartridge"),
		OpticalRoot:   filepath.Join(root, "games", "optical"),
		ModernRoot:    filepath.Join(root, "games", "modern"),
		Pipeline:      &pipeline.Mutex{}, // the shared heavy-job slot, as main.go wires it
	}
	if !gen.Configured() {
		t.Fatal("harness generator not configured")
	}
	srv, err := New(st, scan, WithGenerator(gen))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return genHarness{srv: srv, root: root, gen: gen}
}

func TestGenerateEndpointCSRFAndUnconfigured(t *testing.T) {
	h := newGenServer(t)
	handler := h.srv.Handler()

	// CSRF posture: every mutating endpoint is htmx-only (D-P2c).
	req := httptest.NewRequest("POST", "/generate", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Errorf("POST /generate without X-HX-Request = %d, want 403", rec.Code)
	}

	// Unconfigured generator → 503, consistent with dlControl/acquire/scrape.
	root := t.TempDir()
	st, scan := fixtureScan(t, root)
	srv2, err := New(st, scan) // no WithGenerator
	if err != nil {
		t.Fatal(err)
	}
	if rec := postHX(t, srv2.Handler(), "/generate"); rec.Code != http.StatusServiceUnavailable {
		t.Errorf("POST /generate unconfigured = %d, want 503", rec.Code)
	}
}

func TestGenerateEndpointWritesFilesAndLogs(t *testing.T) {
	h := newGenServer(t)
	rec := postHX(t, h.srv.Handler(), "/generate")
	if rec.Code != http.StatusOK {
		t.Fatalf("POST /generate = %d, want 200 (synchronous)", rec.Code)
	}

	// The served tree now carries the launcher DB with its launch line.
	b, err := os.ReadFile(filepath.Join(h.root, "games", "cartridge", "nes", "metadata.pegasus.txt"))
	if err != nil {
		t.Fatalf("generated file missing: %v", err)
	}
	if !strings.Contains(string(b), `launch: jupiter-retroarch -L fceumm "{file.path}"`) {
		t.Errorf("generated file lacks the catalogue launch line:\n%s", b)
	}

	// A generate run was recorded and the metadata fragment renders the
	// generation log section with it.
	var found bool
	runs, _ := h.srv.st.RecentRuns(10)
	for _, r := range runs {
		if r.Kind == "generate" && r.Status == "ok" {
			found = true
		}
	}
	if !found {
		t.Fatal("no ok kind=generate run recorded")
	}
	frag := get(t, h.srv.Handler(), "/partials/metadata").Body.String()
	if !strings.Contains(frag, `hx-post="/generate"`) {
		t.Error("fragment missing the Regenerate button")
	}
	if !strings.Contains(frag, "data-generate-run") {
		t.Error("fragment missing the generation log rows")
	}
}

func TestGenerateEndpointBusyIs409(t *testing.T) {
	h := newGenServer(t)
	// Hold the shared pipeline slot exactly like a running verify would.
	if !h.gen.Pipeline.TryAcquire() {
		t.Fatal("could not hold the idle pipeline mutex")
	}
	defer h.gen.Pipeline.Release()
	if rec := postHX(t, h.srv.Handler(), "/generate"); rec.Code != http.StatusConflict {
		t.Errorf("POST /generate while busy = %d, want 409", rec.Code)
	}
}

// TestPostVerifyTriggersGeneration pins the trigger point: a successful
// verify (≥1 system verified/promoted) regenerates; a failed one does
// not. Runs through the real handler helper against the real generator.
func TestPostVerifyTriggersGeneration(t *testing.T) {
	h := newGenServer(t)
	countRuns := func() int {
		n := 0
		runs, _ := h.srv.st.RecentRuns(50)
		for _, r := range runs {
			if r.Kind == "generate" {
				n++
			}
		}
		return n
	}

	before := countRuns()
	// Failed batch: no trigger.
	h.srv.maybeGenerateAfterVerify([]igir.SystemOutcome{
		{Sys: "nes", Outcome: igir.OutcomeFailed},
	}, nil)
	// Error return: no trigger even with green outcomes inside.
	h.srv.maybeGenerateAfterVerify([]igir.SystemOutcome{
		{Sys: "nes", Outcome: igir.OutcomeVerified},
	}, errFake)
	if got := countRuns(); got != before {
		t.Fatalf("failed verifies must not regenerate: %d generate runs, want %d", got, before)
	}

	// Success: verified outcome triggers one generation.
	h.srv.maybeGenerateAfterVerify([]igir.SystemOutcome{
		{Sys: "nes", Outcome: igir.OutcomeVerified},
		{Sys: "gb", Outcome: igir.OutcomeSkippedEmpty},
	}, nil)
	if got := countRuns(); got != before+1 {
		t.Fatalf("verified verify did not trigger generation: %d runs, want %d", got, before+1)
	}
	nesFile := filepath.Join(h.root, "games", "cartridge", "nes", "metadata.pegasus.txt")
	if _, err := os.Stat(nesFile); err != nil {
		t.Fatal("post-verify generation wrote nothing")
	}
}

var errFake = &fakeErr{}

type fakeErr struct{}

func (*fakeErr) Error() string { return "fake" }

// TestGenerateRunDetailRendering: the runs-table detail cell renders the
// generate payload humanized (never raw JSON — ADV-P1-05).
func TestGenerateRunDetailRendering(t *testing.T) {
	detail, _ := json.Marshal(struct {
		Systems   []generate.SystemOutcome `json:"Systems"`
		Validated bool                     `json:"Validated"`
		DryRun    bool                     `json:"DryRun"`
	}{[]generate.SystemOutcome{
		{Sys: "nes", Outcome: "generated", Games: 5},
		{Sys: "segacd", Outcome: "generated", Games: 0, Pending: 1},
	}, true, false})
	r := store.Run{ID: 1, Kind: "generate", StartedAt: time.Now().Format(time.RFC3339), FinishedAt: time.Now().Format(time.RFC3339), Status: "ok", Detail: string(detail)}
	html := string(runDetail(r))
	if strings.Contains(html, "{") || strings.Contains(html, `"Systems"`) {
		t.Errorf("raw JSON leaked into the detail cell: %s", html)
	}
	for _, want := range []string{"nes: generated", "5 games", "segacd: generated", "1 pending"} {
		if !strings.Contains(html, want) {
			t.Errorf("detail cell missing %q in %q", want, html)
		}
	}
}
