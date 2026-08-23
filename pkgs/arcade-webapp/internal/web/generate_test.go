package web

import (
	"encoding/json"
	"errors"
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

// TestPostVerifyGenerationBusyRecordsSkipAndRetries pins ADV-P6-03: a
// regeneration that finds the pipeline slot busy is not silent — an
// explicit kind=generate run row marked "skipped" lands in the history
// naming the reason, and exactly ONE deferred retry follows once the
// slot frees (the accepted residual is only a retry that finds it busy
// again).
func TestPostVerifyGenerationBusyRecordsSkipAndRetries(t *testing.T) {
	h := newGenServer(t)
	old := postVerifyRetryDelay
	postVerifyRetryDelay = 50 * time.Millisecond
	t.Cleanup(func() { postVerifyRetryDelay = old })

	genRuns := func() []store.Run {
		t.Helper()
		var out []store.Run
		runs, _ := h.srv.st.RecentRuns(50)
		for _, r := range runs {
			if r.Kind == "generate" {
				out = append(out, r)
			}
		}
		return out
	}

	// Hold the shared pipeline slot exactly like a running scrape would.
	if !h.gen.Pipeline.TryAcquire() {
		t.Fatal("could not hold the idle pipeline mutex")
	}
	h.srv.maybeGenerateAfterVerify([]igir.SystemOutcome{
		{Sys: "nes", Outcome: igir.OutcomeVerified},
	}, nil)

	runs := genRuns()
	if len(runs) != 1 || runs[0].Status != "skipped" {
		t.Fatalf("busy trigger recorded %+v, want exactly one skipped run", runs)
	}
	if !strings.Contains(runs[0].Detail, "pipeline busy") {
		t.Errorf("skip detail = %q, want the pipeline-busy reason (history must be legible)", runs[0].Detail)
	}

	// Free the slot; the single deferred retry lands one more run. Wait
	// for a FINISHED run ("running" rows appear at StartRun time) so no
	// generation goroutine leaks past the test's teardown.
	h.gen.Pipeline.Release()
	finished := func() bool {
		for _, r := range genRuns() {
			if r.Status == "ok" || r.Status == "error" {
				return true
			}
		}
		return false
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) && !finished() {
		time.Sleep(20 * time.Millisecond)
	}
	runs = genRuns()
	if !finished() {
		t.Fatalf("deferred retry never finished: %+v", runs)
	}
	if len(runs) != 2 {
		t.Fatalf("generate runs after retry = %d (%+v), want 2 (skipped + deferred ok)", len(runs), runs)
	}
}

var errFake = &fakeErr{}

type fakeErr struct{}

func (*fakeErr) Error() string { return "fake" }

// TestRegenerationReadsOptionsUnderTheSlot pins ADV-P7-02: the curation
// options are read INSIDE the locked region, so store mutations landing
// while the slot is held are picked up by THIS pass instead of being
// clobbered by a pre-lock stale snapshot (the lost-update interleaving:
// G1 snapshots pre-state → G2 generates post-state and releases → G1
// claims the freed slot and writes stale bytes). The provider IS the
// stall hook: it blocks mid-pass while the test mutates the store.
func TestRegenerationReadsOptionsUnderTheSlot(t *testing.T) {
	h := newGenServer(t)

	inOpts := make(chan struct{})
	release := make(chan struct{})
	done := make(chan error, 1)
	go func() {
		_, err := h.gen.GenerateFresh(false, func() (generate.Options, error) {
			close(inOpts) // both locks HELD; the options read is stalled here
			<-release
			return h.srv.generateOptions()
		})
		done <- err
	}()
	<-inOpts

	// Mutate the store WHILE this generation holds the pipeline slot: a
	// brand-new collection with one nes member.
	cid, err := h.srv.st.CreateCollection("Kitchen Quick-Play", "")
	if err != nil {
		t.Fatal(err)
	}
	games, _ := h.srv.st.ListGames(store.GameListOpts{SystemKey: "nes", Limit: 1})
	if len(games.Games) != 1 {
		t.Fatal("no nes fixture game found")
	}
	g := games.Games[0]
	if err := h.srv.st.AddCollectionGame(cid, g.SystemKey, g.ID); err != nil {
		t.Fatal(err)
	}
	close(release)

	if err := <-done; err != nil {
		t.Fatalf("GenerateFresh: %v", err)
	}
	b, rerr := os.ReadFile(filepath.Join(h.root, "games", "cartridge", "nes", "metadata.pegasus.txt"))
	if rerr != nil {
		t.Fatal(rerr)
	}
	out := string(b)
	for _, want := range []string{generate.CustomCollectionMarker, "shortname: kitchen-quick-play"} {
		if !strings.Contains(out, want) {
			t.Fatalf("mid-slot mutation missing from generated file (stale snapshot):\n%s", out)
		}
	}
}

// TestFreshProviderOnlyRunsUnderLock pins the other half of ADV-P7-02:
// when the pipeline slot is held, GenerateFresh refuses WITHOUT ever
// invoking the provider — an options read outside the locked region is
// exactly the bug class being fixed.
func TestFreshProviderOnlyRunsUnderLock(t *testing.T) {
	h := newGenServer(t)
	if !h.gen.Pipeline.TryAcquire() {
		t.Fatal("could not hold the idle pipeline mutex")
	}
	defer h.gen.Pipeline.Release()

	called := make(chan struct{})
	_, err := h.gen.GenerateFresh(false, func() (generate.Options, error) {
		close(called)
		return generate.Options{}, nil
	})
	if !errors.Is(err, generate.ErrBusy) {
		t.Fatalf("busy slot = %v, want ErrBusy", err)
	}
	select {
	case <-called:
		t.Fatal("provider ran WITHOUT holding the slot (pre-lock snapshot bug)")
	default:
	}
}

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
