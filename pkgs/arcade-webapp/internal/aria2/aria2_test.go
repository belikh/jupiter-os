package aria2

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// testSecret is an INVENTED value for tests only — no real fleet secret
// is ever committed (house rule). The whole point of secretValue in these
// tests is that grep for it must FAIL everywhere except the wire.
const testSecret = "unit-test-rpc-secret-not-real"

// mockRPC is a scripted aria2 JSON-RPC endpoint. It records every
// request's method + params so tests assert the exact wire shape (token
// first, keys filters, the load-bearing empty uris array).
type mockRPC struct {
	mu       sync.Mutex
	requests []mockReq
	// behavior knobs (set per test)
	handler func(method string, params []any) (any, *mockErr)
	status  int    // HTTP status override (transport-failure path)
	body    string // raw body override (malformed path)
	delay   time.Duration
}

type mockReq struct {
	Method string
	Params []any
}

type mockErr struct {
	Code    int
	Message string
}

func (m *mockRPC) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var req struct {
		JSONRPC string `json:"jsonrpc"`
		ID      int64  `json:"id"`
		Method  string `json:"method"`
		Params  []any  `json:"params"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		w.WriteHeader(400)
		return
	}
	m.requests = append(m.requests, mockReq{Method: req.Method, Params: req.Params})

	if m.delay > 0 {
		time.Sleep(m.delay)
	}
	if m.status != 0 {
		w.WriteHeader(m.status)
		return
	}
	if m.body != "" {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, m.body)
		return
	}
	if m.handler == nil {
		w.WriteHeader(500)
		return
	}
	result, rpcErr := m.handler(req.Method, req.Params)
	resp := map[string]any{"jsonrpc": "2.0", "id": req.ID}
	if rpcErr != nil {
		resp["error"] = map[string]any{"code": rpcErr.Code, "message": rpcErr.Message}
	} else {
		resp["result"] = result
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

func (m *mockRPC) reqs() []mockReq {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]mockReq, len(m.requests))
	copy(out, m.requests)
	return out
}

// newMockClient wires a Client at a mock server with a real secret file
// in a temp dir (the runtime-read path is under test too).
func newMockClient(t *testing.T, m *mockRPC) (*Client, *httptest.Server, string) {
	t.Helper()
	srv := httptest.NewServer(m)
	t.Cleanup(srv.Close)

	secretFile := filepath.Join(t.TempDir(), "aria2-secret")
	if err := os.WriteFile(secretFile, []byte(testSecret+"\n"), 0o400); err != nil {
		t.Fatal(err)
	}
	c := New(srv.URL, secretFile, log.New(&bytes.Buffer{}, "", 0))
	c.RetryBackoff = 0
	return c, srv, secretFile
}

func TestTokenIsFirstParamOnEveryMethod(t *testing.T) {
	m := &mockRPC{handler: func(method string, params []any) (any, *mockErr) {
		switch method {
		case "aria2.tellActive":
			if len(params) != 2 { // [keys]
				return nil, &mockErr{1, "unexpected extra params"}
			}
			return nil, nil
		case "aria2.getGlobalStat", "aria2.getVersion":
			if len(params) != 1 {
				return nil, &mockErr{1, "unexpected extra params"}
			}
			return nil, nil
		case "aria2.pause", "aria2.unpause", "aria2.remove":
			if len(params) != 2 || params[1] != "deadbeef00000000" {
				return nil, &mockErr{1, "bad gid param"}
			}
			return nil, nil
		default:
			return nil, &mockErr{1, "unexpected method " + method}
		}
	}}
	c, _, _ := newMockClient(t, m)
	ctx := context.Background()

	if _, err := c.TellActive(ctx); err != nil {
		t.Errorf("TellActive: %v", err)
	}
	if _, err := c.GetGlobalStat(ctx); err != nil {
		t.Errorf("GetGlobalStat: %v", err)
	}
	if _, err := c.GetVersion(ctx); err != nil {
		t.Errorf("GetVersion: %v", err)
	}
	for _, fn := range []func(context.Context, string) error{c.Pause, c.Unpause, c.Remove} {
		if err := fn(ctx, "deadbeef00000000"); err != nil {
			t.Errorf("control call: %v", err)
		}
	}

	for _, req := range m.reqs() {
		if len(req.Params) == 0 || req.Params[0] != "token:"+testSecret {
			t.Errorf("%s: params[0] = %v, want token-first auth", req.Method, req.Params)
		}
	}
}

func TestQueueMethodsParseAria2Shapes(t *testing.T) {
	active := []map[string]any{
		{
			"gid":             "abc12300000000f0",
			"status":          "active",
			"totalLength":     "2097152", // aria2 sends STRINGS
			"completedLength": "524288",
			"downloadSpeed":   "262144",
			"uploadSpeed":     "0",
			"dir":             "/incoming/nes",
			"bittorrent":      map[string]any{"info": map[string]any{"name": "NES Set"}},
			"files":           []map[string]any{{"path": "/incoming/nes/NES Set/payload.bin"}},
		},
		{
			"gid":             "abc12300000000f1",
			"status":          "active",
			"totalLength":     "1024",
			"completedLength": "1024",
			"downloadSpeed":   "0",
			"uploadSpeed":     "4096",
			"dir":             "/tank/downloads",
			"errorMessage":    "",
			"files":           []map[string]any{{"path": "/tank/downloads/linux.iso"}},
		},
	}
	m := &mockRPC{handler: func(method string, params []any) (any, *mockErr) {
		switch method {
		case "aria2.tellActive":
			// The keys filter must be the last param.
			if len(params) != 2 {
				return nil, &mockErr{1, "want [keys]"}
			}
			return active, nil
		case "aria2.tellWaiting", "aria2.tellStopped":
			if len(params) != 4 {
				return nil, &mockErr{1, "want [offset, num, keys]"}
			}
			if params[1] != float64(0) || params[2] != float64(100) {
				return nil, &mockErr{1, "offset/num not forwarded"}
			}
			return []map[string]any{}, nil
		case "aria2.getGlobalStat":
			return map[string]string{
				"numActive": "2", "numWaiting": "5", "numStopped": "1", "numStoppedTotal": "9",
			}, nil
		case "aria2.getVersion":
			return map[string]any{"version": "1.37.0", "enabledFeatures": []string{"BitTorrent"}}, nil
		}
		return nil, &mockErr{1, "unexpected " + method}
	}}
	c, _, _ := newMockClient(t, m)
	ctx := context.Background()

	dls, err := c.TellActive(ctx)
	if err != nil {
		t.Fatalf("TellActive: %v", err)
	}
	if len(dls) != 2 {
		t.Fatalf("TellActive returned %d, want 2", len(dls))
	}
	d := dls[0]
	if d.GID != "abc12300000000f0" || d.TotalLength != 2097152 || d.CompletedLength != 524288 ||
		d.DownloadSpeed != 262144 || d.Dir != "/incoming/nes" {
		t.Errorf("parsed download = %+v", d)
	}
	if d.Name() != "NES Set" {
		t.Errorf("Name() = %q, want torrent info name", d.Name())
	}
	if dls[1].Name() != "linux.iso" {
		t.Errorf("Name() = %q, want first-file basename for http download", dls[1].Name())
	}

	if _, err := c.TellWaiting(ctx, 0, 100); err != nil {
		t.Errorf("TellWaiting: %v", err)
	}
	if _, err := c.TellStopped(ctx, 0, 100); err != nil {
		t.Errorf("TellStopped: %v", err)
	}

	gs, err := c.GetGlobalStat(ctx)
	if err != nil {
		t.Fatalf("GetGlobalStat: %v", err)
	}
	if gs.NumActive != 2 || gs.NumWaiting != 5 || gs.NumStopped != 1 || gs.NumStoppedTotal != 9 {
		t.Errorf("GlobalStat = %+v", gs)
	}

	v, err := c.GetVersion(ctx)
	if err != nil || v.Version != "1.37.0" {
		t.Errorf("GetVersion = %+v, %v", v, err)
	}
}

func TestAddTorrentWireShape(t *testing.T) {
	// A real (self-authored, tiny) torrent file: decode of the b64
	// matters, so use actual bytes.
	torrent := filepath.Join(t.TempDir(), "set.torrent")
	raw := []byte("d4:infod4:name7:fixturee") // bencode-ish placeholder
	if err := os.WriteFile(torrent, raw, 0o444); err != nil {
		t.Fatal(err)
	}

	m := &mockRPC{handler: func(method string, params []any) (any, *mockErr) {
		if method != "aria2.addTorrent" {
			return nil, &mockErr{1, "unexpected " + method}
		}
		// params: [token, b64, uris, options] — the empty uris array
		// is load-bearing (aria2 issue #2075).
		if len(params) != 4 {
			return nil, &mockErr{1, fmt.Sprintf("want 4 params, got %d", len(params))}
		}
		if uris, ok := params[2].([]any); !ok || len(uris) != 0 {
			return nil, &mockErr{1, "uris array must be present and empty"}
		}
		opts, ok := params[3].(map[string]any)
		if !ok {
			return nil, &mockErr{1, "options must be an object"}
		}
		if opts["dir"] != "/incoming/nes" || opts["seed-time"] != "0" ||
			opts["allow-overwrite"] != "true" || opts["check-integrity"] != true {
			return nil, &mockErr{1, fmt.Sprintf("options = %v", opts)}
		}
		return "2080000000000001", nil
	}}
	c, _, _ := newMockClient(t, m)

	gid, err := c.AddTorrent(context.Background(), torrent, AcquireTorrentOptions("/incoming", "nes"))
	if err != nil {
		t.Fatalf("AddTorrent: %v", err)
	}
	if gid != "2080000000000001" {
		t.Errorf("gid = %q", gid)
	}
}

func TestAddURIWireShape(t *testing.T) {
	m := &mockRPC{handler: func(method string, params []any) (any, *mockErr) {
		if method != "aria2.addUri" {
			return nil, &mockErr{1, "unexpected " + method}
		}
		// params: [token, uris, options]
		uris, ok := params[1].([]any)
		if !ok || len(uris) != 1 || uris[0] != "http://127.0.0.1:8099/payload.bin" {
			return nil, &mockErr{1, "bad uris"}
		}
		opts, _ := params[2].(map[string]any)
		if opts["dir"] != "/incoming/nes" {
			return nil, &mockErr{1, "bad dir"}
		}
		return "2080000000000002", nil
	}}
	c, _, _ := newMockClient(t, m)

	gid, err := c.AddURI(context.Background(),
		[]string{"http://127.0.0.1:8099/payload.bin"}, Options{"dir": "/incoming/nes"})
	if err != nil || gid != "2080000000000002" {
		t.Errorf("AddURI = %q, %v", gid, err)
	}
}

func TestCheckIntegrityDependsOnControlFile(t *testing.T) {
	root := t.TempDir()

	// No dir at all -> hash-check (the safe default).
	o := AcquireTorrentOptions(root, "nes")
	if o["check-integrity"] != true {
		t.Errorf("absent dir: check-integrity = %v, want true", o["check-integrity"])
	}

	// Dir with a staged .aria2 control file -> resume straight from it.
	dir := filepath.Join(root, "nes")
	if err := os.MkdirAll(filepath.Join(dir, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "sub", "set.aria2"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	o = AcquireTorrentOptions(root, "nes")
	if o["check-integrity"] != false {
		t.Errorf("control file present: check-integrity = %v, want false", o["check-integrity"])
	}
	if o["dir"] != dir || o["seed-time"] != "0" || o["allow-overwrite"] != "true" {
		t.Errorf("options = %v", o)
	}
}

// TestRPCErrorIsHardResult proves a JSON-RPC error in the 200 body is
// surfaced as *RPCError and NEVER retried (aria2-rpc.sh semantics: those
// are hard results, only transport failures retry).
func TestRPCErrorIsHardResult(t *testing.T) {
	torrent := filepath.Join(t.TempDir(), "set.torrent")
	if err := os.WriteFile(torrent, []byte("d4:infod4:name7:fixturee"), 0o444); err != nil {
		t.Fatal(err)
	}
	m := &mockRPC{handler: func(method string, params []any) (any, *mockErr) {
		return nil, &mockErr{12, "is already registered"} // the re-add error
	}}
	c, _, _ := newMockClient(t, m)

	_, err := c.AddTorrent(context.Background(), torrent, Options{})
	if err == nil {
		t.Fatal("want error")
	}
	var rpcErr *RPCError
	if !errors.As(err, &rpcErr) {
		t.Fatalf("err = %v, want *RPCError", err)
	}
	if rpcErr.Code != 12 || !strings.Contains(rpcErr.Error(), "already registered") {
		t.Errorf("RPCError = %+v", rpcErr)
	}
	if n := len(m.reqs()); n != 1 {
		t.Errorf("JSON-RPC error was retried: %d requests, want 1", n)
	}
}

// TestSubmitRetriesTransportFailureOnly proves submits retry transport
// failures (HTTP 5xx) with backoff and succeed on a later attempt.
func TestSubmitRetriesTransportFailureOnly(t *testing.T) {
	torrent := filepath.Join(t.TempDir(), "set.torrent")
	if err := os.WriteFile(torrent, []byte("d4:infod4:name7:fixturee"), 0o444); err != nil {
		t.Fatal(err)
	}

	var mu sync.Mutex
	calls := 0
	m := &mockRPC{handler: func(method string, params []any) (any, *mockErr) {
		return "2080000000000003", nil
	}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		calls++
		fail := calls < 3
		mu.Unlock()
		if fail {
			w.WriteHeader(502)
			return
		}
		m.ServeHTTP(w, r)
	}))
	t.Cleanup(srv.Close)

	secretFile := filepath.Join(t.TempDir(), "s")
	_ = os.WriteFile(secretFile, []byte(testSecret), 0o400)
	c := New(srv.URL, secretFile, nil)
	c.RetryBackoff = 0

	gid, err := c.AddTorrent(context.Background(), torrent, Options{})
	if err != nil || gid != "2080000000000003" {
		t.Fatalf("AddTorrent = %q, %v (want success on 3rd attempt)", gid, err)
	}
	if calls != 3 {
		t.Errorf("calls = %d, want 3 (fail, fail, ok) with SubmitRetries=2", calls)
	}
}

// TestUnreachableIsTypedTransportError proves a down daemon (connection
// refused) yields *TransportError — what the web layer renders as the
// "aria2 unreachable" state — quickly, with no retry on queries.
func TestUnreachableIsTypedTransportError(t *testing.T) {
	// A server that is closed before the call: connection refused.
	srv := httptest.NewServer(http.NotFoundHandler())
	url := srv.URL
	srv.Close()

	secretFile := filepath.Join(t.TempDir(), "s")
	_ = os.WriteFile(secretFile, []byte(testSecret), 0o400)
	c := New(url, secretFile, nil)

	start := time.Now()
	_, err := c.TellActive(context.Background())
	if err == nil {
		t.Fatal("want error")
	}
	var te *TransportError
	if !errors.As(err, &te) {
		t.Fatalf("err = %v, want *TransportError", err)
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Errorf("query with refused connection took %v — queries must fail fast", elapsed)
	}
}

// TestQueryTimeoutBoundsCall proves the query timeout fires (daemon
// wedged) and is reported as a transport error, not a hang.
func TestQueryTimeoutBoundsCall(t *testing.T) {
	m := &mockRPC{handler: func(string, []any) (any, *mockErr) { return nil, nil }}
	m.delay = 2 * time.Second
	c, _, _ := newMockClient(t, m)
	c.QueryTimeout = 100 * time.Millisecond

	_, err := c.TellActive(context.Background())
	var te *TransportError
	if !errors.As(err, &te) {
		t.Fatalf("err = %v, want *TransportError", err)
	}
	if !errors.Is(err, context.DeadlineExceeded) && !strings.Contains(err.Error(), "deadline") {
		t.Errorf("timeout error should mention the deadline: %v", err)
	}
}

// TestMalformedResponsesAreTransportErrors covers bad bodies (HTML error
// pages, truncated JSON) so the UI degrades to "unreachable", not a panic
// or a 500 with stack noise.
func TestMalformedResponsesAreTransportErrors(t *testing.T) {
	for _, body := range []string{"<html>gateway error</html>", `{"jsonrpc":"2.0","id":1,"res`, ``} {
		m := &mockRPC{body: body}
		c, _, _ := newMockClient(t, m)
		if _, err := c.GetGlobalStat(context.Background()); err == nil {
			t.Errorf("body %q: want error", body)
		} else {
			var te *TransportError
			if !errors.As(err, &te) {
				t.Errorf("body %q: err = %v, want *TransportError", body, err)
			}
			if body != "" && strings.Contains(err.Error(), body) {
				t.Errorf("error leaks response body: %v", err)
			}
		}
	}
}

// TestSecretNeverLogged is the house-critical guarantee (plan R10 /
// AC-2): the RPC secret value must never appear in log output. It runs a
// client through EVERY method and every failure mode with the standard
// logger captured into a buffer, then greps the buffer for the secret.
// It simultaneously proves the secret IS on the wire (the mock saw it),
// so the guarantee can't be vacuously won by never sending it.
func TestSecretNeverLogged(t *testing.T) {
	var logs bytes.Buffer
	log.SetOutput(&logs)
	log.SetFlags(log.LstdFlags)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	// Success-path server.
	m := &mockRPC{handler: func(method string, params []any) (any, *mockErr) {
		switch method {
		case "aria2.tellActive":
			return []map[string]any{{
				"gid": "ffff000000000001", "status": "active",
				"totalLength": "10", "completedLength": "5",
				"downloadSpeed": "1", "dir": "/in/nes",
			}}, nil
		case "aria2.getGlobalStat":
			return map[string]string{"numActive": "1"}, nil
		default:
			return nil, nil
		}
	}}
	c, srv, secretPath := newMockClient(t, m)
	c.log = log.Default()

	ctx := context.Background()
	// Success paths through every method...
	_, _ = c.TellActive(ctx)
	_, _ = c.TellWaiting(ctx, 0, 10)
	_, _ = c.TellStopped(ctx, 0, 10)
	_, _ = c.GetGlobalStat(ctx)
	_, _ = c.GetVersion(ctx)
	_ = c.Pause(ctx, "ffff000000000001")
	_ = c.Unpause(ctx, "ffff000000000001")
	_ = c.Remove(ctx, "ffff000000000001")
	_, _ = c.AddURI(ctx, []string{"http://x/y"}, Options{"dir": "/in/nes"})
	_, _ = c.AddTorrent(ctx, "missing.torrent", Options{})

	// ...then failure modes: unreachable + malformed + JSON-RPC error,
	// all through the captured logger (the timeout path is covered by
	// TestQueryTimeoutBoundsCall).
	dead := New("http://127.0.0.1:1/jsonrpc", secretPath, log.Default())
	dead.RetryBackoff = 0
	_, _ = dead.TellActive(ctx)
	_, _ = dead.AddTorrent(ctx, "t", Options{})

	m.mu.Lock()
	m.status = 500
	m.mu.Unlock()
	_, _ = c.GetGlobalStat(ctx)
	m.mu.Lock()
	m.status, m.body = 0, "<html>oops"
	m.mu.Unlock()
	_, _ = c.GetVersion(ctx)
	m.mu.Lock()
	m.status, m.body = 0, `{"error":{"code":2,"message":"boom"}}`
	m.mu.Unlock()
	_, _ = c.GetVersion(ctx)
	_ = srv // keep the server referenced until the end

	out := logs.String()
	if strings.Contains(out, testSecret) {
		t.Fatalf("SECRET LEAKED into logs:\n%s", out)
	}

	// The secret WAS sent on the wire (non-vacuous guarantee).
	sawToken := false
	for _, req := range m.reqs() {
		if len(req.Params) > 0 && req.Params[0] == "token:"+testSecret {
			sawToken = true
			break
		}
	}
	if !sawToken {
		t.Fatal("client never sent the token — the never-logged guarantee is vacuous")
	}
}

func TestMissingSecretFileIsTransportError(t *testing.T) {
	m := &mockRPC{handler: func(string, []any) (any, *mockErr) { return nil, nil }}
	srv := httptest.NewServer(m)
	t.Cleanup(srv.Close)

	c := New(srv.URL, filepath.Join(t.TempDir(), "nope"), nil)
	_, err := c.GetGlobalStat(context.Background())
	if err == nil {
		t.Fatal("want error for missing secret file")
	}
	var te *TransportError
	if !errors.As(err, &te) {
		t.Fatalf("err = %v, want *TransportError", err)
	}
	if strings.Contains(err.Error(), testSecret) {
		t.Error("error text references the secret value")
	}
}
