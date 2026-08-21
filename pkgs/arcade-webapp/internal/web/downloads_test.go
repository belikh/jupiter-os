package web

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/aria2"
)

// mockAria2 is a scripted aria2 JSON-RPC endpoint for the web layer —
// canned queue state plus call recording for the control endpoints.
type mockAria2 struct {
	mu         sync.Mutex
	server     *httptest.Server
	secretFile string

	calls   map[string]int
	paused  map[string]bool
	removed map[string]bool

	stat      aria2.GlobalStat
	version   string
	active    []aria2.Download
	waiting   []aria2.Download
	stopped   []aria2.Download
	submitErr string // addTorrent fails with this JSON-RPC message
	submitGID string

	// submitHook, when set, observes the addTorrent params (minus the
	// token — params[1:]) before the canned answer.
	submitHook func(method string, params []any)
}

func newMockAria2(t *testing.T) *mockAria2 {
	t.Helper()
	m := &mockAria2{
		calls:   map[string]int{},
		paused:  map[string]bool{},
		removed: map[string]bool{},
		stat: aria2.GlobalStat{
			NumActive: 1, NumWaiting: 2, NumStopped: 3, NumStoppedTotal: 9,
		},
		version:   "1.37.0",
		submitGID: "abcdef0123456789",
	}
	m.secretFile = filepath.Join(t.TempDir(), "secret")
	if err := os.WriteFile(m.secretFile, []byte("web-test-secret"), 0o400); err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/jsonrpc", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Method string `json:"method"`
			Params []any  `json:"params"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			w.WriteHeader(400)
			return
		}
		m.mu.Lock()
		defer m.mu.Unlock()
		m.calls[req.Method]++
		reply := func(result any, code int, msg string) {
			resp := map[string]any{"jsonrpc": "2.0", "id": 1}
			if code != 0 {
				resp["error"] = map[string]any{"code": code, "message": msg}
			} else {
				resp["result"] = result
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(resp)
		}
		switch req.Method {
		case "aria2.getVersion":
			reply(map[string]any{"version": m.version}, 0, "")
		case "aria2.getGlobalStat":
			reply(m.stat, 0, "")
		case "aria2.tellActive":
			reply(dlShapes(m.active, m.paused, m.removed), 0, "")
		case "aria2.tellWaiting":
			reply(dlShapes(m.waiting, m.paused, m.removed), 0, "")
		case "aria2.tellStopped":
			reply(dlShapes(m.stopped, m.paused, m.removed), 0, "")
		case "aria2.pause":
			gid := paramGID(req.Params)
			m.paused[gid] = true
			reply(gid, 0, "")
		case "aria2.unpause":
			gid := paramGID(req.Params)
			m.paused[gid] = false
			reply(gid, 0, "")
		case "aria2.remove":
			gid := paramGID(req.Params)
			m.removed[gid] = true
			reply(gid, 0, "")
		case "aria2.addTorrent":
			if m.submitHook != nil {
				m.submitHook(req.Method, req.Params[1:]) // token stripped
			}
			if m.submitErr != "" {
				reply(nil, 12, m.submitErr)
				return
			}
			reply(m.submitGID, 0, "")
		default:
			reply(nil, 1, "unexpected "+req.Method)
		}
	})
	m.server = httptest.NewServer(mux)
	t.Cleanup(m.server.Close)
	return m
}

// dlShapes converts typed downloads to the wire shape (string numbers).
func dlShapes(dls []aria2.Download, paused, removed map[string]bool) []map[string]any {
	out := []map[string]any{}
	for _, d := range dls {
		if removed[d.GID] {
			continue
		}
		status := d.Status
		if paused[d.GID] {
			status = "paused"
		}
		row := map[string]any{
			"gid": d.GID, "status": status,
			"totalLength":     fmt.Sprint(d.TotalLength),
			"completedLength": fmt.Sprint(d.CompletedLength),
			"downloadSpeed":   fmt.Sprint(d.DownloadSpeed),
			"dir":             d.Dir,
		}
		if d.BitTorrent != nil && d.BitTorrent.Info != nil {
			row["bittorrent"] = map[string]any{"info": map[string]any{"name": d.BitTorrent.Info.Name}}
		}
		out = append(out, row)
	}
	return out
}

func paramGID(params []any) string {
	if len(params) >= 2 {
		if s, ok := params[1].(string); ok {
			return s
		}
	}
	return ""
}

// newDownloadsServer builds the fixture store with download control
// wired at a mock daemon whose active download sits in incoming/nes.
func newDownloadsServer(t *testing.T, root string) (*Server, *mockAria2) {
	t.Helper()

	st, scan := fixtureScan(t, root)
	incoming := filepath.Join(root, "cache", "incoming")
	torrentDir := filepath.Join(root, "metadata", "minerva-torrents")

	// Stage the torrent the fixture catalogue names for nes so the
	// acquire surface renders exercised.
	if err := os.MkdirAll(torrentDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(torrentDir, "T.torrent"), []byte("d4:infod4:name2:nee"), 0o444); err != nil {
		t.Fatal(err)
	}

	m := newMockAria2(t)
	cl := aria2.New(m.server.URL+"/jsonrpc", m.secretFile, nil)
	cl.QueryTimeout = 500 * time.Millisecond

	srv, err := New(st, scan, WithAria2(cl, incoming, torrentDir))
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	m.mu.Lock()
	m.active = []aria2.Download{{
		GID:             "abcdef0123456789",
		Status:          "active",
		TotalLength:     2097152,
		CompletedLength: 524288,
		DownloadSpeed:   262144,
		Dir:             filepath.Join(incoming, "nes"),
		Files:           []aria2.DownloadFile{{Path: filepath.Join(incoming, "nes", "nes-set", "payload.bin")}},
	}}
	m.mu.Unlock()
	return srv, m
}

func postHX(t *testing.T, h http.Handler, path string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest("POST", path, nil)
	req.Header.Set("X-HX-Request", "true")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestDownloadsPageRendersQueueAndJoin(t *testing.T) {
	root := t.TempDir()
	srv, _ := newDownloadsServer(t, root)

	rec := get(t, srv.Handler(), "/downloads")
	if rec.Code != 200 {
		t.Fatalf("GET /downloads: status = %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	for _, marker := range []string{
		`id="downloads-panel"`,
		`hx-trigger="every 2s"`, // AC-2: 2s queue poll
		`aria-live="polite"`,    // a11y: polled region announced
		`data-gid="abcdef0123456789"`,
		`data-system="nes"`, // dir attribution: incoming/nes -> nes
		`role="progressbar"`,
		`aria-valuenow="25"`, // 524288/2097152
		`hx-post="/downloads/abcdef0123456789/pause"`,
		`aria2 1.37.0`, // getVersion surfaced
		"1 active",     // global stat chips
		`>acquire</button>`,
		">unknown</span>", // verify join renders the DB's (unknown) state
	} {
		if !strings.Contains(body, marker) {
			t.Errorf("GET /downloads: body missing marker %q", marker)
		}
	}
	if !strings.Contains(body, "<html") {
		t.Error("page render must carry the full layout")
	}
}

func TestDownloadsFragmentIsFragment(t *testing.T) {
	root := t.TempDir()
	srv, _ := newDownloadsServer(t, root)

	rec := get(t, srv.Handler(), "/partials/downloads")
	if rec.Code != 200 {
		t.Fatalf("GET /partials/downloads: status = %d", rec.Code)
	}
	body := rec.Body.String()
	if strings.Contains(body, "<html") {
		t.Error("fragment must not render the page layout")
	}
	if !strings.Contains(body, `id="downloads-panel"`) {
		t.Error("fragment missing its panel id (the hx target)")
	}
}

// TestDownloadsSummaryFragment covers the dashboard's download surface
// (the P1 critic's named gap): counts, throughput, errored.
func TestDownloadsSummaryFragment(t *testing.T) {
	root := t.TempDir()
	srv, m := newDownloadsServer(t, root)

	rec := get(t, srv.Handler(), "/partials/downloads-summary")
	body := rec.Body.String()
	if !strings.Contains(body, `data-aria2="ok"`) {
		t.Errorf("summary should show reachable daemon: %s", body)
	}
	if !strings.Contains(body, "1 active") || !strings.Contains(body, "2 waiting") {
		t.Errorf("summary missing queue depth: %s", body)
	}
	if !strings.Contains(body, "256.0 KiB/s") {
		t.Errorf("summary missing throughput: %s", body)
	}

	// Daemon down -> "aria2 unreachable" state chip, still HTTP 200.
	srv.a2 = aria2.New("http://127.0.0.1:1/jsonrpc", m.secretFile, nil)
	rec = get(t, srv.Handler(), "/partials/downloads-summary")
	if rec.Code != 200 {
		t.Fatalf("summary with dead daemon: status = %d, want 200", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "aria2 unreachable") {
		t.Errorf("dead daemon should render 'aria2 unreachable': %s", rec.Body.String())
	}
}

// TestUnreachableQueueIsStateNot500 proves the queue fragment degrades
// to a rendered state (never a 500) when the daemon is down.
func TestUnreachableQueueIsStateNot500(t *testing.T) {
	root := t.TempDir()
	srv, m := newDownloadsServer(t, root)
	srv.a2 = aria2.New("http://127.0.0.1:1/jsonrpc", m.secretFile, nil)

	for _, path := range []string{"/downloads", "/partials/downloads"} {
		rec := get(t, srv.Handler(), path)
		if rec.Code != 200 {
			t.Errorf("GET %s with dead daemon: status = %d, want 200", path, rec.Code)
		}
		if !strings.Contains(rec.Body.String(), "aria2 unreachable") {
			t.Errorf("GET %s: missing unreachable state", path)
		}
	}
}

// TestNotConfiguredDownloads covers the nil-client surface.
func TestNotConfiguredDownloads(t *testing.T) {
	srv := newTestServer(t) // no WithAria2 option
	for _, path := range []string{"/downloads", "/partials/downloads"} {
		rec := get(t, srv.Handler(), path)
		if rec.Code != 200 {
			t.Fatalf("GET %s: status = %d, want 200", path, rec.Code)
		}
	}
	body := get(t, srv.Handler(), "/partials/downloads").Body.String()
	if !strings.Contains(body, "not configured") {
		t.Errorf("nil client should render 'not configured': %s", body)
	}
	sum := get(t, srv.Handler(), "/partials/downloads-summary").Body.String()
	if !strings.Contains(sum, "not configured") {
		t.Errorf("summary with nil client: %s", sum)
	}
}

// TestAcquireSubmitsTorrentWithScriptSemantics proves the per-system
// acquire action: torrent basename from the catalogue, dir routing into
// incoming/<sys>, aria2-rpc.sh's option shape, and an 'acquire' run
// recorded for the audit trail.
func TestAcquireSubmitsTorrentWithScriptSemantics(t *testing.T) {
	root := t.TempDir()
	srv, m := newDownloadsServer(t, root) // stages metadata/minerva-torrents/T.torrent
	var mu sync.Mutex
	var gotParams []any
	var gotMethod string
	m.mu.Lock()
	m.submitHook = func(method string, params []any) {
		mu.Lock()
		defer mu.Unlock()
		gotMethod, gotParams = method, params
	}
	m.mu.Unlock()

	rec := postHX(t, srv.Handler(), "/systems/nes/acquire")
	if rec.Code != 202 {
		t.Fatalf("POST /systems/nes/acquire: status = %d, want 202", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), `id="downloads-panel"`) {
		t.Error("acquire must answer with the refreshed queue fragment")
	}

	mu.Lock()
	defer mu.Unlock()
	if gotMethod != "aria2.addTorrent" {
		t.Fatalf("daemon saw method %q, want aria2.addTorrent", gotMethod)
	}
	if len(gotParams) != 3 { // [b64, uris, options] after token strip
		t.Fatalf("addTorrent params = %v, want [b64, [], options]", gotParams)
	}
	if uris, ok := gotParams[1].([]any); !ok || len(uris) != 0 {
		t.Errorf("uris array must be present and empty (aria2 #2075): %v", gotParams[1])
	}
	opts, _ := gotParams[2].(map[string]any)
	want := filepath.Join(root, "cache", "incoming", "nes")
	if opts["dir"] != want {
		t.Errorf("options dir = %v, want %v", opts["dir"], want)
	}
	if opts["seed-time"] != "0" || opts["allow-overwrite"] != "true" {
		t.Errorf("seed-time/allow-overwrite wrong: %v", opts)
	}
	if opts["check-integrity"] != true {
		t.Errorf("no .aria2 control file staged -> check-integrity must be true: %v", opts)
	}

	// The audit trail records the acquire run.
	runs, err := srv.st.RecentRuns(3)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, r := range runs {
		if r.Kind == "acquire" && r.Status == "ok" && strings.Contains(r.Detail, `"gid"`) {
			found = true
		}
	}
	if !found {
		t.Errorf("no ok 'acquire' run recorded: %+v", runs)
	}
}

// TestAcquireFailureModes: unknown system, torrentless catalogue row,
// missing staged file, daemon rejection — each surfaces on the fragment,
// still 202 + panel (the queue itself may be healthy).
func TestAcquireFailureModes(t *testing.T) {
	root := t.TempDir()
	srv, m := newDownloadsServer(t, root)
	h := srv.Handler()

	cases := []struct {
		path, wantErr string
	}{
		{"/systems/nosuch/acquire", "unknown system"},
		{"/systems/gb/acquire", "no torrent"},           // gb's TSV torrent column is "-"
		{"/systems/snes/acquire", "torrent not staged"}, // snes -> T2.torrent absent
	}
	for _, tc := range cases {
		rec := postHX(t, h, tc.path)
		if rec.Code != 202 {
			t.Errorf("POST %s: status = %d, want 202", tc.path, rec.Code)
			continue
		}
		if !strings.Contains(rec.Body.String(), tc.wantErr) {
			t.Errorf("POST %s: fragment missing %q", tc.path, tc.wantErr)
		}
	}

	// Daemon hard-rejects the submission (aria2 code 12 shape).
	m.mu.Lock()
	m.submitErr = "is already registered"
	m.mu.Unlock()
	rec := postHX(t, h, "/systems/nes/acquire")
	if rec.Code != 202 || !strings.Contains(rec.Body.String(), "already registered") {
		t.Errorf("daemon rejection should surface: %d %s", rec.Code, rec.Body.String())
	}

	// …and the failed submit is recorded as an error run.
	runs, err := srv.st.RecentRuns(2)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) == 0 || runs[0].Kind != "acquire" || runs[0].Status != "error" {
		t.Errorf("failed acquire not recorded as error run: %+v", runs)
	}
}

func TestDownloadControlsCallDaemon(t *testing.T) {
	root := t.TempDir()
	srv, m := newDownloadsServer(t, root)
	h := srv.Handler()

	for _, action := range []string{"pause", "resume", "remove"} {
		rec := postHX(t, h, "/downloads/abcdef0123456789/"+action)
		if rec.Code != 200 {
			t.Errorf("%s: status = %d", action, rec.Code)
		}
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.calls["aria2.pause"] != 1 || m.calls["aria2.unpause"] != 1 || m.calls["aria2.remove"] != 1 {
		t.Errorf("control calls = %v", m.calls)
	}
}

// TestMutatingEndpointsRequireHTMXHeader is the CSRF posture: a plain
// cross-site form post (no X-HX-Request) is rejected on EVERY mutating
// endpoint, including P1's /rescan (ADV-P1-07 closed).
func TestMutatingEndpointsRequireHTMXHeader(t *testing.T) {
	root := t.TempDir()
	srv, _ := newDownloadsServer(t, root)
	h := srv.Handler()

	for _, path := range []string{
		"/rescan",
		"/systems/nes/acquire",
		"/downloads/abcdef0123456789/pause",
		"/downloads/abcdef0123456789/resume",
		"/downloads/abcdef0123456789/remove",
	} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("POST", path, nil))
		if rec.Code != http.StatusForbidden {
			t.Errorf("POST %s without X-HX-Request: status = %d, want 403", path, rec.Code)
		}
	}
}

// TestSystemJoinStateMachine drives the P2 centerpiece join with fixture
// store data: attribution by dir, downloading/queued/errored aggregation,
// torrent availability, and the idle collapse.
func TestSystemJoinStateMachine(t *testing.T) {
	root := t.TempDir()
	srv, m := newDownloadsServer(t, root)

	incoming := filepath.Join(root, "cache", "incoming")
	m.mu.Lock()
	m.active = []aria2.Download{
		{GID: "a1", Status: "active", Dir: filepath.Join(incoming, "nes"),
			TotalLength: 1000, CompletedLength: 500},
		{GID: "a2", Status: "active", Dir: filepath.Join(incoming, "snes"),
			TotalLength: 200, CompletedLength: 200},
	}
	m.waiting = []aria2.Download{
		{GID: "w1", Status: "waiting", Dir: filepath.Join(incoming, "gb")},
	}
	m.stopped = []aria2.Download{
		{GID: "s1", Status: "error", Dir: filepath.Join(incoming, "nes"), ErrorMessage: "tracker down"},
		{GID: "s2", Status: "complete", Dir: "/tank/downloads/linux.iso"}, // not ours
	}
	m.mu.Unlock()

	vm := srv.fetchDownloads(context.Background())

	byKey := map[string]systemDL{}
	for _, s := range vm.Systems {
		byKey[s.Key] = s
	}

	nes := byKey["nes"]
	if !nes.Errored || !nes.Downloading || nes.GIDs != 2 {
		t.Errorf("nes join = %+v (want errored+downloading, 2 gids)", nes)
	}
	if nes.ActivePct != 50 {
		t.Errorf("nes ActivePct = %d, want 50", nes.ActivePct)
	}
	snes := byKey["snes"]
	if !snes.Downloading || snes.ActivePct != 100 {
		t.Errorf("snes join = %+v (want downloading 100%%)", snes)
	}
	gb := byKey["gb"]
	if !gb.Queued || gb.Downloading {
		t.Errorf("gb join = %+v (want queued only)", gb)
	}

	// Torrent availability: nes's T.torrent is staged by the helper,
	// gb has no catalogue torrent.
	if nes.TorrentName != "T.torrent" || !nes.TorrentOK {
		t.Errorf("nes torrent = %q ok=%v, want staged T.torrent", nes.TorrentName, nes.TorrentOK)
	}
	if gb.TorrentName != "" {
		t.Errorf("gb has no catalogue torrent, got %q", gb.TorrentName)
	}

	// The non-arcade download must not attribute to any system.
	for _, s := range vm.Systems {
		if s.Key == "linux.iso" || s.Key == "downloads" {
			t.Errorf("non-arcade download attributed to system %q", s.Key)
		}
	}
	// Idle collapse: the 3-system fixture has none (every system has
	// games/DAT/torrent signal); the collapse path is exercised on the
	// VM test's 61-system catalogue. Pin that the join listed them all.
	if vm.IdleCount != 0 || len(vm.Systems) != 3 {
		t.Errorf("join = %d listed, %d idle; want 3 listed, 0 idle", len(vm.Systems), vm.IdleCount)
	}
}

// TestQueueRowButtonsByStatus pins the button visibility matrix.
func TestQueueRowButtonsByStatus(t *testing.T) {
	root := t.TempDir()
	srv, _ := newDownloadsServer(t, root)
	incoming := filepath.Join(root, "cache", "incoming")

	queue := []aria2.Download{
		{GID: "g1", Status: "active", Dir: filepath.Join(incoming, "nes")},
		{GID: "g2", Status: "waiting", Dir: incoming},
		{GID: "g3", Status: "paused", Dir: incoming},
		{GID: "g4", Status: "complete", Dir: incoming},
		{GID: "g5", Status: "error", Dir: incoming, ErrorMessage: "boom"},
		{GID: "g6", Status: "removed", Dir: incoming},
	}
	rows := srv.queueRows(queue)
	wantPause := map[string]bool{"g1": true, "g2": true, "g3": false, "g4": false, "g5": false, "g6": false}
	wantResume := map[string]bool{"g1": false, "g2": false, "g3": true, "g4": false, "g5": false, "g6": false}
	wantRemove := map[string]bool{"g1": true, "g2": true, "g3": true, "g4": true, "g5": true, "g6": false}
	for _, r := range rows {
		if r.CanPause != wantPause[r.GID] {
			t.Errorf("%s pause = %v", r.GID, r.CanPause)
		}
		if r.CanResume != wantResume[r.GID] {
			t.Errorf("%s resume = %v", r.GID, r.CanResume)
		}
		if r.CanRemove != wantRemove[r.GID] {
			t.Errorf("%s remove = %v", r.GID, r.CanRemove)
		}
	}
}

// TestDirAttributionBoundaries: the incoming root itself, paths outside
// it, and deeper nesting never attribute.
func TestDirAttributionBoundaries(t *testing.T) {
	root := t.TempDir()
	srv, _ := newDownloadsServer(t, root)
	incoming := filepath.Join(root, "cache", "incoming")

	cases := map[string]string{
		filepath.Join(incoming, "nes"):        "nes",
		filepath.Join(incoming, "nes") + "/":  "nes", // trailing slash
		incoming:                              "",
		filepath.Join(incoming, "nes", "sub"): "",
		"/tank/downloads":                     "",
		"":                                    "",
	}
	for dir, want := range cases {
		if got := srv.systemForDir(dir); got != want {
			t.Errorf("systemForDir(%q) = %q, want %q", dir, got, want)
		}
	}
}
