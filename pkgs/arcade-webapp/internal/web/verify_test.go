package web

import (
	"bytes"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/aria2"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/dats"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/fixture"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/igir"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// newVerifyServer builds the fixture store + a REAL igir.Runner over a
// fake igir binary (argv-recording test double; the VM test exercises
// the real binary) + a DAT fetcher against a stub host.
func newVerifyServer(t *testing.T) (*Server, *httptest.Server) {
	t.Helper()
	root := t.TempDir()
	st, scan := fixtureScan(t, root)

	// Stage the nes corpus under incoming so a verify has something to
	// chew (the fake igir copies inputs to output + writes the report).
	nes := fixture.Systems()[0]
	inSys := filepath.Join(root, "cache", "incoming", "nes")
	if err := os.MkdirAll(inSys, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, g := range nes.Games {
		b := fixture.RomBytes(fixture.RomKey(nes, g), g.Size)
		if err := os.WriteFile(filepath.Join(inSys, fixture.RomFileName(nes, g)), b, 0o644); err != nil {
			t.Fatal(err)
		}
	}

	// Fake igir: copy inputs to --output, write a FOUND-per-input report.
	fakeBin := filepath.Join(root, "fake-igir")
	script := `#!/bin/sh
in=""; out=""; rep=""
while [ $# -gt 0 ]; do
  case "$1" in
    --input) in="$2"; shift 2 ;;
    --output) out="$2"; shift 2 ;;
    --report-output) rep="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$out" "$(dirname "$rep")"
printf '%s\n' 'DAT Name,Game Name,Status,ROM Files,Patched,BIOS,Retail Release,Unlicensed,Debug,Demo,Beta,Sample,Prototype,Program,Aftermarket,Homebrew,Bad' > "$rep"
for f in "$in"/*; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  cp "$f" "$out/"
  printf '%s\n' "Fake DAT,$b,FOUND,$out/$b,false,false,true,false,false,false,false,false,false,false,false,false" >> "$rep"
done
`
	if err := os.WriteFile(fakeBin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	reportDir := filepath.Join(root, "scratch", "reports")
	runner, nerr := igir.New(igir.Config{
		Binary:        fakeBin,
		IncomingDir:   filepath.Join(root, "cache", "incoming"),
		DATDir:        filepath.Join(root, "metadata", "no-intro-dats"),
		CartridgeRoot: filepath.Join(root, "games", "cartridge"),
		OpticalRoot:   filepath.Join(root, "games", "optical"),
		ModernRoot:    filepath.Join(root, "games", "modern"),
		ReportDir:     reportDir,
	}, st, nil, nil)
	if nerr != nil {
		t.Fatalf("igir.New: %v", nerr)
	}

	// Stub Fresh1G1R: serves the gb fixture DAT for any *.dat path.
	stub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, ".dat") {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte(fixture.DAT(fixture.Systems()[2])))
	}))
	t.Cleanup(stub.Close)

	fetcher := &dats.Fetcher{
		BaseURL: stub.URL,
		Dir:     filepath.Join(root, "metadata", "no-intro-dats"),
		St:      st,
	}

	srv, err := New(st, scan, WithPipeline(runner, fetcher))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return srv, stub
}

func TestVerifyPageRendersWorklist(t *testing.T) {
	srv, _ := newVerifyServer(t)

	rec := get(t, srv.Handler(), "/verify")
	if rec.Code != 200 {
		t.Fatalf("GET /verify: status = %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	for _, marker := range []string{
		`id="verify-panel"`,
		`hx-trigger="every 2s"`, // minutes-long igir runs → 2s poll
		`aria-live="polite"`,    // a11y carry: polled region announced
		`hx-post="/verify"`,     // verify-all
		`hx-post="/dats/refresh"`,
		`hx-post="/systems/nes/verify"`, // per-system verify
		`hx-post="/systems/nes/dat-refresh"`,
		`data-system="nes" data-verify="unknown"`, // pill live but unpopulated pre-verify
		`data-system="snes"`,
		"Verify all",
		">nes</span>", // the worklist rows
	} {
		if !strings.Contains(body, marker) {
			t.Errorf("GET /verify: body missing marker %q", marker)
		}
	}
	// No batch running → no progressbar (a11y: only in-flight carries one).
	if strings.Contains(body, `role="progressbar"`) {
		t.Error("idle verify page must not render a progressbar")
	}

	frag := get(t, srv.Handler(), "/partials/verify")
	if strings.Contains(frag.Body.String(), "<html") {
		t.Error("verify partial rendered the full layout")
	}
}

// TestVerifyPillStates drives every zero-unmatched classification
// through the real store + templates: green (found==dat_games, nothing
// extra), amber (missing), red (unmatched), grey (unchecked / unknown).
func TestVerifyPillStates(t *testing.T) {
	srv, _ := newVerifyServer(t)

	stamp := time.Now().UTC().Format(time.RFC3339)
	shapes := []struct {
		sys  string
		vr   store.VerifyResult
		want string
		pill string
	}{
		{"nes", store.VerifyResult{SystemKey: "nes", FinishedAt: stamp, DatGames: 5, Found: 5}, "verified", `<span class="pill ok"`},
		{"snes", store.VerifyResult{SystemKey: "snes", FinishedAt: stamp, DatGames: 4, Found: 2, Missing: 2}, "missing", `2 missing`},
		{"gb", store.VerifyResult{SystemKey: "gb", FinishedAt: stamp, DatGames: 4, Found: 4, Unmatched: 3}, "unmatched", `3 unmatched`},
	}
	// gb needs its own store row shape — the fixture TSV has gb, so use a
	// fourth state on a re-verified gb below instead.
	for _, s := range shapes {
		if err := srv.st.RecordVerifyResult(s.vr); err != nil {
			t.Fatal(err)
		}
	}

	body := get(t, srv.Handler(), "/").Body.String()
	for _, s := range shapes {
		if !strings.Contains(body, `data-system="`+s.sys+`" data-games="`) {
			t.Fatalf("card for %s missing", s.sys)
		}
	}
	if !strings.Contains(body, `data-system="nes" data-games="5" data-coverage="60" data-verify="verified"`) {
		t.Error("nes card must carry data-verify=verified")
	}
	if !strings.Contains(body, `data-system="snes" data-games="4" data-coverage="0" data-verify="missing"`) {
		t.Error("snes card must carry data-verify=missing")
	}
	if !strings.Contains(body, `data-system="gb" data-games="4" data-coverage="0" data-verify="unmatched"`) {
		t.Error("gb card must carry data-verify=unmatched")
	}
	if !strings.Contains(body, `<span class="pill ok" title="5 of 5 DAT games found, 0 unmatched">verified</span>`) {
		t.Error("green pill text missing")
	}
	if !strings.Contains(body, `2 missing`) || !strings.Contains(body, `3 unmatched`) {
		t.Error("amber/red pill counts missing")
	}

	// Unchecked (grey): replace gb's row with an unchecked promote.
	if err := srv.st.RecordVerifyResult(store.VerifyResult{SystemKey: "gb", FinishedAt: stamp, Unchecked: 1, PromotedBytes: 4096}); err != nil {
		t.Fatal(err)
	}
	body = get(t, srv.Handler(), "/").Body.String()
	if !strings.Contains(body, `data-system="gb" data-games="4" data-coverage="0" data-verify="unchecked"`) {
		t.Error("gb card must carry data-verify=unchecked")
	}
	if !strings.Contains(body, ">unchecked</span>") {
		t.Error("unchecked pill text missing")
	}

	// Re-verify echo (the real-igir shape proven in the VM bring-up):
	// every DAT game FOUND again, and the staged input re-seen in the
	// output as DUPLICATE echoes — COPY semantics keep the staged tree,
	// so this is what EVERY second verify looks like. Must stay GREEN
	// (the original classifier counted duplicates red, flipping every
	// green system red on its second verify).
	if err := srv.st.RecordVerifyResult(store.VerifyResult{SystemKey: "nes", FinishedAt: stamp, DatGames: 5, Found: 5, Duplicate: 5}); err != nil {
		t.Fatal(err)
	}
	body = get(t, srv.Handler(), "/").Body.String()
	if !strings.Contains(body, `data-system="nes" data-games="5" data-coverage="60" data-verify="verified"`) {
		t.Error("nes re-verify with output echoes must STAY verified (idempotency)")
	}
	if !strings.Contains(body, `title="5 of 5 DAT games found, 0 unmatched (5 already-promoted echo)"`) {
		t.Error("echo count must surface in the pill title")
	}

	// Extra (amber): all DAT games found, but the games tree holds files
	// the DAT doesn't claim (operator drops / scanner fixtures) — a
	// deviation worth surfacing, milder than junk arriving in staging.
	if err := srv.st.RecordVerifyResult(store.VerifyResult{SystemKey: "gb", FinishedAt: stamp, DatGames: 4, Found: 4, Extra: 2}); err != nil {
		t.Fatal(err)
	}
	body = get(t, srv.Handler(), "/").Body.String()
	if !strings.Contains(body, `data-system="gb" data-games="4" data-coverage="0" data-verify="extra"`) {
		t.Error("gb card must carry data-verify=extra")
	}
	if !strings.Contains(body, `>2 extra</span>`) {
		t.Error("extra pill count missing")
	}

	// The downloads systems table shares the same indicator (needs the
	// downloads-configured server — its systems table renders only then).
	root := t.TempDir()
	dls, _ := newDownloadsServer(t, root)
	if err := dls.st.RecordVerifyResult(store.VerifyResult{
		SystemKey: "nes", FinishedAt: stamp, DatGames: 5, Found: 5,
	}); err != nil {
		t.Fatal(err)
	}
	dl := get(t, dls.Handler(), "/downloads").Body.String()
	if !strings.Contains(dl, `data-system="nes"`) || !strings.Contains(dl, ">verified</span>") {
		t.Error("downloads join must render the same verify pill")
	}
}

// TestVerifyLastAttemptFailedMarker (ADV-P3-02): a re-verify whose
// report fails to parse returns BEFORE RecordVerifyResult, so the pill
// keeps rendering the last GOOD ingest (by design — the ingested report
// is the authority) with the error visible only in runs/LastError. The
// fragment must carry an honesty marker when a system's newest verify
// attempt failed without ingesting, and clear it once a newer attempt
// ingests again.
func TestVerifyLastAttemptFailedMarker(t *testing.T) {
	srv, _ := newVerifyServer(t)
	stamp := time.Now().UTC().Format(time.RFC3339)

	finishVerifyRun := func(status string, systems []igir.SystemOutcome) int64 {
		t.Helper()
		runID, err := srv.st.StartRun("verify")
		if err != nil {
			t.Fatal(err)
		}
		detail, err := json.Marshal(verifyRunDetail{Systems: systems})
		if err != nil {
			t.Fatal(err)
		}
		if err := srv.st.FinishRun(runID, status, string(detail)); err != nil {
			t.Fatal(err)
		}
		return runID
	}

	// Run 1: a successful verify that INGESTED (the last good report).
	runID := finishVerifyRun("ok", []igir.SystemOutcome{
		{Sys: "nes", Outcome: igir.OutcomeVerified, DatGames: 5, Found: 5},
	})
	if err := srv.st.RecordVerifyResult(store.VerifyResult{
		SystemKey: "nes", RunID: runID, FinishedAt: stamp, DatGames: 5, Found: 5,
	}); err != nil {
		t.Fatal(err)
	}

	frag := get(t, srv.Handler(), "/partials/verify").Body.String()
	if !strings.Contains(frag, `data-system="nes" data-verify="verified"`) {
		t.Fatal("precondition: nes must render its green pill from the ingested report")
	}
	if strings.Contains(frag, "last attempt failed") {
		t.Error("marker must not render while the newest attempt ingested fine")
	}

	// Run 2 (newer): the ADV-P3-02 shape — igir died / the report failed
	// to parse, so the runner recorded a failed outcome and the early
	// return skipped RecordVerifyResult entirely.
	finishVerifyRun("error", []igir.SystemOutcome{
		{Sys: "nes", Outcome: igir.OutcomeFailed, Err: "igir: report: open /scratch/reports/nes.csv: no such file or directory"},
	})

	frag = get(t, srv.Handler(), "/partials/verify").Body.String()
	if !strings.Contains(frag, `data-system="nes" data-verify="verified"`) {
		t.Error("the pill must still render the last GOOD ingest (the report is authoritative)")
	}
	if !strings.Contains(frag, ">last attempt failed</span>") {
		t.Error("a failed attempt newer than the last ingest must render the honesty marker")
	}
	if !strings.Contains(frag, `title="last attempt failed — showing last good report"`) {
		t.Error("marker tooltip must say the report shown is the last good one")
	}

	// Run 3 (newest): a successful attempt that ingests again — marker clears.
	runID3 := finishVerifyRun("ok", []igir.SystemOutcome{
		{Sys: "nes", Outcome: igir.OutcomeVerified, DatGames: 5, Found: 5},
	})
	if err := srv.st.RecordVerifyResult(store.VerifyResult{
		SystemKey: "nes", RunID: runID3, FinishedAt: stamp, DatGames: 5, Found: 5, Duplicate: 5,
	}); err != nil {
		t.Fatal(err)
	}
	frag = get(t, srv.Handler(), "/partials/verify").Body.String()
	if strings.Contains(frag, "last attempt failed") {
		t.Error("marker must clear once a newer attempt ingests")
	}
}

// TestVerifyFlowEndToEnd: POST per-system verify → 202, the runner
// (fake igir) promotes + ingests, the fragment flips to verified, the
// report link serves the CSV, and the runs table records kind=verify.
func TestVerifyFlowEndToEnd(t *testing.T) {
	srv, _ := newVerifyServer(t)

	rec := postHX(t, srv.Handler(), "/systems/nes/verify")
	if rec.Code != http.StatusAccepted {
		t.Fatalf("POST /systems/nes/verify: status = %d, want 202", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), `id="verify-panel"`) {
		t.Error("verify POST must answer the fragment")
	}

	// The background runner lands the result; poll the fragment.
	verified := false
	for i := 0; i < 50 && !verified; i++ {
		body := get(t, srv.Handler(), "/partials/verify").Body.String()
		if strings.Contains(body, `data-system="nes" data-verify="verified"`) {
			verified = true
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !verified {
		t.Fatal("nes never flipped to verified after POST /systems/nes/verify")
	}

	// Report link + CSV served (catalogue-keyed).
	rep := get(t, srv.Handler(), "/verify/reports/nes.csv")
	if rep.Code != 200 {
		t.Fatalf("GET /verify/reports/nes.csv: status = %d", rep.Code)
	}
	if ct := rep.Header().Get("Content-Type"); !strings.Contains(ct, "text/csv") {
		t.Errorf("report Content-Type = %q", ct)
	}
	if !strings.Contains(rep.Body.String(), ",FOUND,") {
		t.Error("report CSV must contain FOUND rows")
	}

	// Dashboard card live (report-driven pill).
	if !strings.Contains(get(t, srv.Handler(), "/").Body.String(), `data-verify="verified"`) {
		t.Error("card wall pill did not flip after verify")
	}

	// Runs table: verify run with the human-facing detail (not raw JSON).
	status := get(t, srv.Handler(), "/partials/status").Body.String()
	if !strings.Contains(status, "<td>verify</td>") {
		t.Error("verify run not recorded in runs table")
	}
	if !strings.Contains(status, "nes: verified") {
		t.Error("verify run detail must render per-system outcome lines")
	}

	// Unknown system → 404; traversal-shaped keys → 404 too (the report
	// route whitelists against the catalogue).
	if rec := get(t, srv.Handler(), "/verify/reports/nope.csv"); rec.Code != 404 {
		t.Errorf("report for unknown system = %d, want 404", rec.Code)
	}
	if rec := get(t, srv.Handler(), "/verify/reports/..%2F..%2Fetc%2Fpasswd.csv"); rec.Code != 404 {
		t.Errorf("traversal-shaped report key = %d, want 404", rec.Code)
	}
}

// TestDATRefreshViaStub: per-system refresh through the stub host
// updates dat_info (currency without a rescan); the unmapped system
// surfaces its mapping error on the fragment (200-with-error, not 5xx);
// the wiiu case is asserted via a catalogue-less fixture — here the
// fixture TSV has no unmapped system, so the happy path + run record
// carry the proof (the unmapped shape is unit-proved in internal/dats).
func TestDATRefreshViaStub(t *testing.T) {
	srv, _ := newVerifyServer(t)

	rec := postHX(t, srv.Handler(), "/systems/nes/dat-refresh")
	if rec.Code != 200 {
		t.Fatalf("POST /systems/nes/dat-refresh: status = %d, want 200", rec.Code)
	}
	// The stub serves the gb fixture DAT — nes's dat_info now reads the
	// gb header (4 roms). Proves the fetch + re-parse path end-to-end.
	info, err := srv.st.DATInfo("nes")
	if err != nil || info == nil {
		t.Fatalf("DATInfo(nes) after refresh = %v, %v", info, err)
	}
	if info.RomCount != 4 {
		t.Errorf("DATInfo(nes).RomCount after stubbed refresh = %d, want 4 (gb fixture header)", info.RomCount)
	}
	runs := get(t, srv.Handler(), "/partials/status").Body.String()
	if !strings.Contains(runs, "<td>dat-fetch</td>") {
		t.Error("dat-fetch run not recorded")
	}
}

// TestDATRefreshAllSurvivesHandlerReturn: refresh-ALL kicks its batch in
// the background, so the fetches must outlive the HTTP request. Handing
// the goroutine r.Context() would cancel every fetch the moment
// ServeHTTP returns (net/http cancels request contexts at handler
// return) — the endpoint would 202 and then record a run whose every
// fetch failed "context canceled". The fix hands the batch
// context.Background() (each fetch keeps its own 60s cap; the scheduled
// refresh in main.go does the same). NOTE the POST goes through a REAL
// http.Server (httptest.NewServer): a recorder-based request carries
// context.Background() nobody ever cancels, so it cannot see this bug.
func TestDATRefreshAllSurvivesHandlerReturn(t *testing.T) {
	srv, _ := newVerifyServer(t)

	hs := httptest.NewServer(srv.Handler())
	t.Cleanup(hs.Close)
	req, err := http.NewRequest(http.MethodPost, hs.URL+"/dats/refresh", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("X-HX-Request", "true")
	resp, err := hs.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close() //nolint:errcheck // test
	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("POST /dats/refresh over real HTTP: status = %d, want 202", resp.StatusCode)
	}

	// The fixture catalogue (nes/snes/gb) is fully McLean-mapped and the
	// stub serves every *.dat: a surviving batch fetches all three.
	deadline := time.Now().Add(10 * time.Second)
	var last *store.Run
	for time.Now().Before(deadline) {
		r, err := srv.st.LastRun()
		if err != nil {
			t.Fatal(err)
		}
		if r != nil && r.Kind == "dat-fetch" && r.Status != "running" {
			last = r
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if last == nil {
		t.Fatal("background dat-fetch run never finished within 10s")
	}
	var res struct {
		Fetched  int      `json:"Fetched"`
		Warnings []string `json:"Warnings"`
	}
	if err := json.Unmarshal([]byte(last.Detail), &res); err != nil {
		t.Fatalf("dat-fetch detail not JSON: %v (%q)", err, last.Detail)
	}
	if res.Fetched != 3 {
		t.Errorf("refresh-all fetched %d DATs, want 3 (warnings: %v)", res.Fetched, res.Warnings)
	}
	for _, w := range res.Warnings {
		if strings.Contains(w, "context canceled") {
			t.Errorf("background fetch died with the request context: %s", w)
		}
	}
}

// TestVerifyCSRFAndNotConfigured: every new mutating endpoint is
// htmx-only; without the pipeline wired the POSTs answer 503 and the
// page renders its not-configured state.
func TestVerifyCSRFAndNotConfigured(t *testing.T) {
	srv, _ := newVerifyServer(t)
	for _, path := range []string{"/verify", "/systems/nes/verify", "/dats/refresh", "/systems/nes/dat-refresh"} {
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, httptest.NewRequest("POST", path, nil))
		if rec.Code != 403 {
			t.Errorf("POST %s without X-HX-Request = %d, want 403", path, rec.Code)
		}
	}

	bare := newTestServer(t) // no WithPipeline
	if rec := get(t, bare.Handler(), "/verify"); rec.Code != 200 {
		t.Fatalf("GET /verify (unconfigured) = %d, want 200", rec.Code)
	}
	if !strings.Contains(get(t, bare.Handler(), "/verify").Body.String(), "igir not configured") {
		t.Error("unconfigured verify page must say so")
	}
	for _, path := range []string{"/verify", "/systems/nes/verify", "/dats/refresh", "/systems/nes/dat-refresh"} {
		if rec := postHX(t, bare.Handler(), path); rec.Code != 503 {
			t.Errorf("POST %s unconfigured = %d, want 503", path, rec.Code)
		}
	}
}

// ---- torrent staging (the P2 critic's carry-in) -----------------------------

// stageBody builds a multipart body with one .torrent file field.
func stageBody(t *testing.T, filename string, content []byte) (*bytes.Buffer, string) {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	fw, err := mw.CreateFormFile("torrent", filename)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := fw.Write(content); err != nil {
		t.Fatal(err)
	}
	if err := mw.Close(); err != nil {
		t.Fatal(err)
	}
	return &buf, mw.FormDataContentType()
}

func TestStageTorrentValidation(t *testing.T) {
	root := t.TempDir()
	srv, _ := newDownloadsServer(t, root)

	// CSRF.
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/systems/snes/stage-torrent", nil)
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != 403 {
		t.Errorf("stage-torrent without X-HX-Request = %d, want 403", rec.Code)
	}
	// Unknown system.
	if rec := postHX(t, srv.Handler(), "/systems/nope/stage-torrent"); rec.Code != 404 {
		t.Errorf("stage-torrent unknown system = %d, want 404", rec.Code)
	}
	// gb has no torrent in the fixture catalogue ("-").
	if rec := postHX(t, srv.Handler(), "/systems/gb/stage-torrent"); rec.Code != 400 {
		t.Errorf("stage-torrent for torrent-less system = %d, want 400", rec.Code)
	}
	// Not a .torrent.
	body, ct := stageBody(t, "evil.sh", []byte("#!/bin/sh\n"))
	req = httptest.NewRequest("POST", "/systems/snes/stage-torrent", body)
	req.Header.Set("X-HX-Request", "true")
	req.Header.Set("Content-Type", ct)
	rec = httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != 400 {
		t.Errorf("stage-torrent with .sh upload = %d, want 400", rec.Code)
	}

	// Happy path: stored under the CATALOGUE-expected name (T2.torrent).
	body, ct = stageBody(t, "my dump.torrent", []byte("d4:infod4:name4:snes"))
	req = httptest.NewRequest("POST", "/systems/snes/stage-torrent", body)
	req.Header.Set("X-HX-Request", "true")
	req.Header.Set("Content-Type", ct)
	rec = httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("stage-torrent happy path = %d: %s", rec.Code, rec.Body.String())
	}
	b, err := os.ReadFile(filepath.Join(root, "metadata", "minerva-torrents", "T2.torrent"))
	if err != nil {
		t.Fatalf("catalogue-named torrent missing: %v", err)
	}
	if string(b) != "d4:infod4:name4:snes" {
		t.Errorf("stored torrent content = %q", b)
	}
	// The stage run is in the audit trail.
	runs, _ := srv.st.RecentRuns(5)
	found := false
	for _, r := range runs {
		if r.Kind == "stage-torrent" && r.Status == "ok" {
			found = true
		}
	}
	if !found {
		t.Error("stage-torrent run not recorded")
	}
}

// TestStageTorrentRefusesExistingTarget (ADV-P3-04): the store step
// must open with O_CREATE|O_EXCL|O_NOFOLLOW — whatever already sits at
// torrentDir/<catalogue-name> (a regular file OR a pre-planted symlink)
// fails loudly with 409 instead of being overwritten/followed. Not
// remotely reachable today (root-owned dir, catalogue-whitelisted
// names); the flag pair makes it structurally impossible anyway.
func TestStageTorrentRefusesExistingTarget(t *testing.T) {
	root := t.TempDir()
	srv, _ := newDownloadsServer(t, root)
	tdir := filepath.Join(root, "metadata", "minerva-torrents")

	upload := func() *httptest.ResponseRecorder {
		b, c := stageBody(t, "my snes set.torrent", []byte("d4:infod4:name4:snes-NEW"))
		req := httptest.NewRequest("POST", "/systems/snes/stage-torrent", b)
		req.Header.Set("X-HX-Request", "true")
		req.Header.Set("Content-Type", c)
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)
		return rec
	}

	// 1. Existing regular file at the catalogue name: 409, NOT overwritten.
	staged := filepath.Join(tdir, "T2.torrent")
	if err := os.WriteFile(staged, []byte("ORIGINAL"), 0o644); err != nil {
		t.Fatal(err)
	}
	if rec := upload(); rec.Code != http.StatusConflict {
		t.Errorf("re-upload over an existing torrent = %d, want 409", rec.Code)
	}
	if got, _ := os.ReadFile(staged); string(got) != "ORIGINAL" {
		t.Errorf("existing torrent was modified: %q, want ORIGINAL", got)
	}

	// 2. Pre-planted SYMLINK at the catalogue name: refused, NOT followed.
	target := filepath.Join(root, "evil-payload.bin")
	if err := os.WriteFile(target, []byte("PRECIOUS"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(staged); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, staged); err != nil {
		t.Fatal(err)
	}
	if rec := upload(); rec.Code != http.StatusConflict {
		t.Errorf("upload through a pre-planted symlink = %d, want 409 (not followed)", rec.Code)
	}
	if got, _ := os.ReadFile(target); string(got) != "PRECIOUS" {
		t.Errorf("symlink target was written through: %q, want PRECIOUS", got)
	}
	// The symlink itself is left in place — the operator removes it
	// deliberately; the handler only refuses to write through it.
	fi, err := os.Lstat(staged)
	if err != nil || fi.Mode()&os.ModeSymlink == 0 {
		t.Errorf("the pre-planted symlink must survive untouched (err=%v)", err)
	}
}

func TestStageURIValidationAndSubmit(t *testing.T) {
	root := t.TempDir()
	srv, m := newDownloadsServer(t, root)

	m.mu.Lock()
	m.submitHook = func(method string, params []any) {
		if method != "aria2.addUri" {
			return
		}
		// params[1:] = [uris, options] (token stripped by the hook).
		if len(params) < 2 {
			return
		}
		uris, _ := params[0].([]any)
		if len(uris) != 1 || uris[0] != "magnet:?xt=urn:btih:abcdef0123456789" {
			t.Errorf("addUri uris = %v", uris)
		}
		opts, _ := params[1].(map[string]any)
		if opts["dir"] != filepath.Join(root, "cache", "incoming", "nes") {
			t.Errorf("addUri dir = %v, want incoming/nes routing", opts["dir"])
		}
		if opts["seed-time"] != "0" {
			t.Errorf("addUri seed-time = %v, want 0 (acquire shape)", opts["seed-time"])
		}
	}
	m.mu.Unlock()

	postFormHX := func(sys, uri string) *httptest.ResponseRecorder {
		req := httptest.NewRequest("POST", "/systems/"+sys+"/stage-uri", strings.NewReader("uri="+strings.ReplaceAll(uri, "?", "%3F")+"&x=1"))
		req.Header.Set("X-HX-Request", "true")
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)
		return rec
	}

	if rec := postFormHX("nes", "magnet:?xt=urn:btih:abcdef0123456789"); rec.Code != 200 {
		t.Fatalf("stage-uri magnet = %d: %s", rec.Code, rec.Body.String())
	}
	if rec := postFormHX("nes", "ftp://example.com/set.torrent"); rec.Code != 400 {
		t.Errorf("stage-uri ftp = %d, want 400", rec.Code)
	}
	if rec := postFormHX("nes", "not a uri"); rec.Code != 400 {
		t.Errorf("stage-uri garbage = %d, want 400", rec.Code)
	}
	if rec := postFormHX("nope", "magnet:?xt=urn:btih:x"); rec.Code != 404 {
		t.Errorf("stage-uri unknown system = %d, want 404", rec.Code)
	}

	// CSRF + not-configured.
	req := httptest.NewRequest("POST", "/systems/nes/stage-uri", strings.NewReader("uri=magnet:?xt=1"))
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != 403 {
		t.Errorf("stage-uri without header = %d, want 403", rec.Code)
	}
	bare := newTestServer(t) // no aria2
	if rec := postHX(t, bare.Handler(), "/systems/nes/stage-uri"); rec.Code != 503 {
		t.Errorf("stage-uri unconfigured = %d, want 503", rec.Code)
	}
}

var _ = json.Marshal // acquire detail parity kept for future assertions
var _ = aria2.Options{}
