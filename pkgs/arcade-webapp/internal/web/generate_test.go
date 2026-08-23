package web

import (
	"encoding/json"
	"errors"
	"fmt"
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
	waitRegenSettled(t, h.srv, 1)
	if got := countRuns(); got != before+1 {
		t.Fatalf("verified verify did not trigger generation: %d runs, want %d", got, before+1)
	}
	nesFile := filepath.Join(h.root, "games", "cartridge", "nes", "metadata.pegasus.txt")
	if _, err := os.Stat(nesFile); err != nil {
		t.Fatal("post-verify generation wrote nothing")
	}
}

// TestPostVerifyGenerationBusyRecordsSkipAndRetries pins the deferral
// contract as refined by ADV-P7-03: a regeneration that finds the
// pipeline slot busy is not silent — ONE coalesced kind=generate run row
// marked "skipped" lands in the history naming the reason AND its
// post-verify provenance, and the worker keeps retrying until the slot
// frees (no more per-click rows, no more single AfterFunc).
func TestPostVerifyGenerationBusyRecordsSkipAndRetries(t *testing.T) {
	h := newGenServer(t)
	old := regenBusyBackoff
	regenBusyBackoff = 50 * time.Millisecond
	t.Cleanup(func() { regenBusyBackoff = old })

	// Hold the shared pipeline slot exactly like a running scrape would.
	if !h.gen.Pipeline.TryAcquire() {
		t.Fatal("could not hold the idle pipeline mutex")
	}
	h.srv.maybeGenerateAfterVerify([]igir.SystemOutcome{
		{Sys: "nes", Outcome: igir.OutcomeVerified},
	}, nil)

	var skipped *store.Run
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) && skipped == nil {
		time.Sleep(20 * time.Millisecond)
		runs := generateRunsOf(t, h.srv)
		for i := range runs {
			if runs[i].Status == "skipped" {
				skipped = &runs[i]
			}
		}
	}
	if skipped == nil {
		t.Fatal("busy trigger recorded no skipped run row")
	}
	if len(generateRunsOf(t, h.srv)) != 1 {
		t.Fatalf("generate runs while busy = %+v, want exactly one skipped row", generateRunsOf(t, h.srv))
	}
	if !strings.Contains(skipped.Detail, "pipeline busy") || !strings.Contains(skipped.Detail, regenOriginPostVerify) {
		t.Errorf("skip detail = %q, want the pipeline-busy reason with post-verify provenance (history must be legible)", skipped.Detail)
	}

	// Free the slot; the worker's retry lands one more run. Wait for a
	// FINISHED ok/error row ("running" rows appear at StartRun time) so
	// no generation goroutine leaks past the test's teardown.
	h.gen.Pipeline.Release()
	waitRegenSettled(t, h.srv, 1)
	runs := generateRunsOf(t, h.srv)
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

// ---- ADV-P7-03 coordinator helpers + tests ----------------------------------

// generateRunsOf returns every kind=generate run, newest first.
func generateRunsOf(t *testing.T, srv *Server) []store.Run {
	t.Helper()
	runs, err := srv.st.RecentRuns(200)
	if err != nil {
		t.Fatal(err)
	}
	var out []store.Run
	for _, r := range runs {
		if r.Kind == "generate" {
			out = append(out, r)
		}
	}
	return out
}

// waitRegenSettled waits until the coordinator has no pending work AND
// at least minRuns finished ok/error generate runs exist (a "running"
// row means a pass is mid-flight; skipped rows never count toward
// minRuns). The quiescence point is the coordinator's own passActive
// flag: the failure marker lands under the same unlock that clears it,
// so "settled" guarantees every page render sees the final outcome.
func waitRegenSettled(t *testing.T, srv *Server, minRuns int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
		srv.regenMu.Lock()
		pending := srv.regen.dirty || srv.regen.passActive
		srv.regenMu.Unlock()
		if pending {
			continue
		}
		n, running := 0, 0
		for _, r := range generateRunsOf(t, srv) {
			switch {
			case r.Status == "running":
				running++
			case r.FinishedAt != "" && (r.Status == "ok" || r.Status == "error"):
				n++
			}
		}
		if n >= minRuns && running == 0 {
			return
		}
	}
	t.Fatalf("regeneration never settled within the deadline (runs: %+v)", generateRunsOf(t, srv))
}

// TestRegenBurstCoalescing pins ADV-P7-03's core claim: 50 rapid
// curation toggles cost 1–2 generations — not 50 goroutines, 50 run rows
// and a flooded history. The final toggle's state must be what the last
// generation served.
func TestRegenBurstCoalescing(t *testing.T) {
	h := newGenServer(t)
	handler := h.srv.Handler()

	games, _ := h.srv.st.ListGames(store.GameListOpts{SystemKey: "nes", Limit: 1})
	if len(games.Games) != 1 {
		t.Fatal("no nes fixture game found")
	}
	g := games.Games[0]
	ep := fmt.Sprintf("/systems/%s/games/%d/hide", g.SystemKey, g.ID)

	for i := 0; i < 50; i++ {
		if rec := postHX(t, handler, ep); rec.Code != http.StatusOK {
			t.Fatalf("toggle %d = %d, want 200", i, rec.Code)
		}
	}

	waitRegenSettled(t, h.srv, 1)

	var finished, running int
	for _, r := range generateRunsOf(t, h.srv) {
		switch {
		case r.Status == "running":
			running++
		case r.Status == "ok" || r.Status == "error":
			finished++
		default:
			t.Fatalf("unexpected run row %+v (slot was never contended — no skips allowed)", r)
		}
	}
	if running != 0 {
		t.Fatalf("%d generation(s) still running after settle", running)
	}
	if finished < 1 || finished > 2 {
		t.Fatalf("50 rapid toggles produced %d generations, want 1–2 (coalescing broken)", finished)
	}

	// The final toggle (even count = visible again) is what's served.
	pg, _ := h.srv.st.ListGames(store.GameListOpts{SystemKey: g.SystemKey})
	for _, row := range pg.Games {
		if row.ID == g.ID && row.Hidden {
			t.Fatal("final state lost: game still hidden after an even number of toggles")
		}
	}
	b, err := os.ReadFile(filepath.Join(h.root, "games", "cartridge", "nes", "metadata.pegasus.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "file: "+g.RelPath+"\n") {
		t.Fatalf("served tree does not reflect the final toggle state:\n%s", b)
	}
}

// TestRegenDeferralCoalescedPerEpisode pins the deferral contract: while
// a verify holds the slot, N mutations + a post-verify trigger produce
// exactly ONE skipped row per episode, labeled accurately ("regeneration
// deferred — pipeline busy") with BOTH provenances named; when the slot
// frees, exactly one more generation lands.
func TestRegenDeferralCoalescedPerEpisode(t *testing.T) {
	h := newGenServer(t)
	old := regenBusyBackoff
	regenBusyBackoff = 20 * time.Millisecond
	t.Cleanup(func() { regenBusyBackoff = old })

	if !h.gen.Pipeline.TryAcquire() {
		t.Fatal("could not hold the idle pipeline mutex")
	}

	ep := func(id int64) string {
		return fmt.Sprintf("/systems/nes/games/%d/hide", id)
	}
	games, _ := h.srv.st.ListGames(store.GameListOpts{SystemKey: "nes", Limit: 3})
	if len(games.Games) < 3 {
		t.Fatal("fixture nes games missing")
	}
	for _, g := range games.Games { // three curation clicks against a busy slot
		if rec := postHX(t, h.srv.Handler(), ep(g.ID)); rec.Code != http.StatusOK {
			t.Fatalf("hide %d = %d", g.ID, rec.Code)
		}
	}
	h.srv.maybeGenerateAfterVerify([]igir.SystemOutcome{
		{Sys: "nes", Outcome: igir.OutcomeVerified},
	}, nil) // …plus the post-verify trigger

	// Let several backoff cycles elapse, then demand ONE deferral row.
	time.Sleep(150 * time.Millisecond)
	var skips []store.Run
	for _, r := range generateRunsOf(t, h.srv) {
		if r.Status == "skipped" {
			skips = append(skips, r)
		}
	}
	if len(skips) != 1 {
		t.Fatalf("skipped rows during one busy episode = %d (%+v), want 1 (coalesced)", len(skips), skips)
	}
	for _, want := range []string{"regeneration deferred — pipeline busy", regenOriginCuration, regenOriginPostVerify} {
		if !strings.Contains(skips[0].Detail, want) {
			t.Errorf("deferral detail %q missing %q (labels must be accurate)", skips[0].Detail, want)
		}
	}

	h.gen.Pipeline.Release()
	waitRegenSettled(t, h.srv, 1)
	total := len(generateRunsOf(t, h.srv))
	if total != 2 {
		t.Fatalf("generate runs after episode = %d, want 2 (one coalesced skip + one deferred pass)", total)
	}
}

// TestRegenFailureMarkerSurfacesToPages pins ADV-P7-01(b): when a
// hide-toggle's background regeneration ends in failure, the next page
// renders carry a visible warning marker (collections panel, metadata
// panel, game actions); the next fully-ok generation clears it.
func TestRegenFailureMarkerSurfacesToPages(t *testing.T) {
	h := newGenServer(t)
	handler := h.srv.Handler()

	games, _ := h.srv.st.ListGames(store.GameListOpts{SystemKey: "nes", Limit: 1})
	g := games.Games[0]

	// Sabotage the served tree: the generator fails this system loudly
	// ("games dir missing") instead of writing anything.
	nesDir := filepath.Join(h.root, "games", "cartridge", "nes")
	if err := os.RemoveAll(nesDir); err != nil {
		t.Fatal(err)
	}

	if rec := postHX(t, handler, fmt.Sprintf("/systems/%s/games/%d/hide", g.SystemKey, g.ID)); rec.Code != http.StatusOK {
		t.Fatalf("hide = %d, want 200", rec.Code)
	}
	waitRegenSettled(t, h.srv, 1) // settled with an ERROR-status run

	marker := "launcher-DB regeneration failed"
	for path, frag := range map[string]string{
		"/partials/collections": "partial-collections",
		"/partials/metadata":    "partial-metadata",
	} {
		body := get(t, handler, path).Body.String()
		if !strings.Contains(body, marker) {
			t.Errorf("%s missing the regeneration-failure marker:\n%s", frag, body)
		}
	}
	detail := get(t, handler, fmt.Sprintf("/systems/%s/games/%d", g.SystemKey, g.ID)).Body.String()
	if !strings.Contains(detail, marker) {
		t.Error("game page missing the regeneration-failure marker after its hide regenerated into failure")
	}

	// Recovery: restore the dir and regenerate manually → marker clears.
	if err := os.MkdirAll(nesDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if rec := postHX(t, handler, "/generate"); rec.Code != http.StatusOK {
		t.Fatalf("manual regenerate after recovery = %d, want 200", rec.Code)
	}
	for _, path := range []string{"/partials/collections", "/partials/metadata"} {
		if body := get(t, handler, path).Body.String(); strings.Contains(body, marker) {
			t.Errorf("%s still shows the failure marker after a clean generation:\n%s", path, body)
		}
	}
}
