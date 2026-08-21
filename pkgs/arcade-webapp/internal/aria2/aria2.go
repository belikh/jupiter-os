// Package aria2 is the arcade webapp's client for the fleet aria2
// daemon's JSON-RPC endpoint (modules/services/aria2.nix, :6800). It
// ports the semantics of scripts/aria2-rpc.sh — the thin client the
// acquire oneshot has used in production since the Minerva bulk stage:
//
//   - The RPC secret is read from its FILE at call time (sops decrypts
//     the value at activation; the app only ever sees the path) and sent
//     as the first params entry, "token:<secret>", per the aria2 RPC
//     spec. The secret value must NEVER appear in logs or error text —
//     the package never wraps request bodies or the token into errors,
//     and client_test.go greps every log line of a full client run for
//     it (TestSecretNeverLogged).
//   - A JSON-RPC error in a 200 body is a HARD result and is never
//     retried; only transport failures (timeout, HTTP >= 400, dial
//     refused) are retried, and only for submissions — queue queries
//     fail fast so the dashboard renders its "aria2 unreachable" state
//     instead of hanging the poll.
//   - addTorrent sends the load-bearing EMPTY uris array (aria2 issue
//     #2075: the options struct is ignored unless a — even empty — uris
//     list is present) and routes per-system downloads with dir=.
//
// Daemon slowness background (from aria2-rpc.sh): the RPC endpoint
// shares aria2's single-threaded event loop with all download/socket
// I/O, so a busy daemon can take a long time to answer even trivial
// requests (observed >30s getVersion, >120s addTorrent on large sets).
// Timeouts are therefore generous for submissions and short for polls.
package aria2

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// TransportError marks a failure to get a usable RPC response at all
// (dial refused, timeout, HTTP >= 400, malformed body). The web layer
// renders these as the dashboard's "aria2 unreachable" state instead of
// a 500.
type TransportError struct {
	Method string
	Err    error
}

func (e *TransportError) Error() string { return fmt.Sprintf("aria2: %s: %v", e.Method, e.Err) }
func (e *TransportError) Unwrap() error { return e.Err }

// RPCError is a hard JSON-RPC error the daemon answered on HTTP 200
// (aria2 codes: 1 unhandled, 2 not-found/paused-active variants,
// 12 "already registered", ...). Never retried.
type RPCError struct {
	Method  string
	Code    int
	Message string
}

func (e *RPCError) Error() string {
	return fmt.Sprintf("aria2: %s: code %d: %s", e.Method, e.Code, e.Message)
}

// ErrCodeAlreadyRegistered is aria2's code-12 "is already registered":
// re-adding a torrent the daemon already knows fails with it and never
// creates a duplicate download. A submit that lands here AFTER a retry
// (e.g. an ambiguous addTorrent timeout) therefore means the download
// IS registered — callers treat it as success-with-existing-download,
// the same semantics jupiter-rom-acquire's rerun path relies on.
const ErrCodeAlreadyRegistered = 12

// IsAlreadyRegistered reports whether err is the daemon's
// duplicate-infohash code-12 answer.
func IsAlreadyRegistered(err error) bool {
	var re *RPCError
	return errors.As(err, &re) && re.Code == ErrCodeAlreadyRegistered
}

// Options is a per-download aria2 options struct (dir, seed-time,
// allow-overwrite, check-integrity, ...). Values marshal as given — the
// fleet's proven shapes are string options ("seed-time":"0") and the
// boolean check-integrity, exactly like aria2-rpc.sh builds them.
type Options map[string]any

// jsonInt accepts aria2's string-encoded numbers and real JSON numbers
// alike (defensive: some proxies re-encode).
type jsonInt int64

func (v *jsonInt) UnmarshalJSON(b []byte) error {
	s := strings.Trim(strings.TrimSpace(string(b)), `"`)
	if s == "" || s == "null" {
		*v = 0
		return nil
	}
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return fmt.Errorf("aria2: bad number %q", s)
	}
	*v = jsonInt(n)
	return nil
}

// btMeta is the bittorrent object of a torrent download (only the
// display name is kept).
type btMeta struct {
	Info *struct {
		Name string `json:"name"`
	} `json:"info"`
}

// DownloadFile is one file of a download (the first one names HTTP
// downloads, which have no bittorrent.info).
type DownloadFile struct {
	Path string `json:"path"`
}

// Download is one entry of tellActive/tellWaiting/tellStopped, filtered
// to the keys the queue view needs. aria2 returns every numeric field
// as a STRING in its JSON; they are parsed into int64 here.
type Download struct {
	GID             string         `json:"gid"`
	Status          string         `json:"status"` // active|waiting|paused|error|complete|removed
	TotalLength     int64          `json:"-"`
	CompletedLength int64          `json:"-"`
	DownloadSpeed   int64          `json:"-"`
	UploadSpeed     int64          `json:"-"`
	Dir             string         `json:"dir"`
	ErrorMessage    string         `json:"errorMessage"`
	BitTorrent      *btMeta        `json:"bittorrent"`
	Files           []DownloadFile `json:"files"`
}

// Name returns a human-facing name: the torrent's info name, else the
// first file's basename (HTTP downloads), else the dir basename.
func (d Download) Name() string {
	if d.BitTorrent != nil && d.BitTorrent.Info != nil && d.BitTorrent.Info.Name != "" {
		return d.BitTorrent.Info.Name
	}
	for _, f := range d.Files {
		if f.Path != "" {
			return filepath.Base(f.Path)
		}
	}
	return filepath.Base(d.Dir)
}

// ProgressPct returns completed/total as a whole percentage (0 when the
// total is still unknown — HTTP without Content-Length).
func (d Download) ProgressPct() int {
	if d.TotalLength <= 0 {
		return 0
	}
	pct := d.CompletedLength * 100 / d.TotalLength
	if pct > 100 {
		pct = 100
	}
	return int(pct)
}

// rawDownload mirrors aria2's wire shape before parsing into Download.
type rawDownload struct {
	GID             string         `json:"gid"`
	Status          string         `json:"status"`
	TotalLength     jsonInt        `json:"totalLength"`
	CompletedLength jsonInt        `json:"completedLength"`
	DownloadSpeed   jsonInt        `json:"downloadSpeed"`
	UploadSpeed     jsonInt        `json:"uploadSpeed"`
	Dir             string         `json:"dir"`
	ErrorMessage    string         `json:"errorMessage"`
	BitTorrent      *btMeta        `json:"bittorrent"`
	Files           []DownloadFile `json:"files"`
}

// GlobalStat is aria2.getGlobalStat's result (queue depth at a glance;
// string-encoded on the wire like every aria2 number).
type GlobalStat struct {
	NumActive       int64
	NumWaiting      int64
	NumStopped      int64
	NumStoppedTotal int64
}

func (g *GlobalStat) UnmarshalJSON(b []byte) error {
	var raw struct {
		NumActive       jsonInt `json:"numActive"`
		NumWaiting      jsonInt `json:"numWaiting"`
		NumStopped      jsonInt `json:"numStopped"`
		NumStoppedTotal jsonInt `json:"numStoppedTotal"`
	}
	if err := json.Unmarshal(b, &raw); err != nil {
		return err
	}
	*g = GlobalStat{
		NumActive:       int64(raw.NumActive),
		NumWaiting:      int64(raw.NumWaiting),
		NumStopped:      int64(raw.NumStopped),
		NumStoppedTotal: int64(raw.NumStoppedTotal),
	}
	return nil
}

// Version is aria2.getVersion's result.
type Version struct {
	Version         string   `json:"version"`
	EnabledFeatures []string `json:"enabledFeatures"`
}

// Client talks to one aria2 daemon. Safe for concurrent use; build with
// New (the zero value is not usable).
type Client struct {
	url        string
	secretFile string

	// QueryTimeout bounds every queue/stat/version call (fail fast so
	// the UI renders "unreachable" instead of hanging the 2s poll).
	QueryTimeout time.Duration
	// SubmitTimeout bounds addUri/addTorrent attempts; the daemon can
	// legitimately chew on a large metainfo for a long time (see the
	// package comment).
	SubmitTimeout time.Duration
	// SubmitRetries is how many times a SUBMIT transport failure is
	// retried (with backoff); queue/control calls are never retried.
	SubmitRetries int
	// RetryBackoff is the base of the exponential submit-retry backoff
	// (2^(n-1) * base). Tests set it to zero.
	RetryBackoff time.Duration

	hc  *http.Client
	id  atomic.Int64
	log *log.Logger
}

// New builds a client for the daemon at url (e.g.
// "http://127.0.0.1:6800/jsonrpc") whose RPC secret lives in secretFile
// (read at call time, never cached, never logged).
func New(url, secretFile string, logger *log.Logger) *Client {
	return &Client{
		url:           url,
		secretFile:    secretFile,
		QueryTimeout:  3 * time.Second,
		SubmitTimeout: 120 * time.Second,
		SubmitRetries: 2,
		RetryBackoff:  time.Second,
		hc:            &http.Client{},
		log:           logger,
	}
}

// Configured reports whether download control is wired at all.
func (c *Client) Configured() bool { return c != nil && c.url != "" }

// queueKeys is the key filter every tell* call sends — only what the
// queue view renders, not the full objects.
var queueKeys = []string{
	"gid", "status", "totalLength", "completedLength",
	"downloadSpeed", "uploadSpeed", "dir", "errorMessage",
	"bittorrent", "files",
}

// rpcRequest is the JSON-RPC 2.0 envelope; params always start with the
// token (added by call, never by callers).
type rpcRequest struct {
	JSONRPC string `json:"jsonrpc"`
	ID      int64  `json:"id"`
	Method  string `json:"method"`
	Params  []any  `json:"params"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      *int64          `json:"id"`
	Result  json.RawMessage `json:"result"`
	Error   *struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

// call performs one JSON-RPC round trip, reading the secret fresh. The
// request body is NEVER included in any error (it carries the token).
func (c *Client) call(ctx context.Context, method string, timeout time.Duration, params ...any) (json.RawMessage, error) {
	secret, err := readSecret(c.secretFile)
	if err != nil {
		return nil, &TransportError{Method: method, Err: err}
	}
	body, err := json.Marshal(rpcRequest{
		JSONRPC: "2.0",
		ID:      c.id.Add(1),
		Method:  method,
		Params:  append([]any{"token:" + secret}, params...),
	})
	if err != nil {
		return nil, &TransportError{Method: method, Err: err}
	}

	cctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(cctx, http.MethodPost, c.url, bytes.NewReader(body))
	if err != nil {
		return nil, &TransportError{Method: method, Err: err}
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.hc.Do(req)
	if err != nil {
		// Dial/timeout errors — no response body exists to leak.
		return nil, &TransportError{Method: method, Err: unwrapCtxErr(cctx, err)}
	}
	defer resp.Body.Close() //nolint:errcheck // read-only

	if resp.StatusCode >= 400 {
		return nil, &TransportError{Method: method, Err: fmt.Errorf("http %d", resp.StatusCode)}
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 64<<20)) // rpc-max-request-size=64M parity, response side
	if err != nil {
		return nil, &TransportError{Method: method, Err: err}
	}
	var out rpcResponse
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, &TransportError{Method: method, Err: errors.New("malformed response")}
	}
	if out.Error != nil {
		return nil, &RPCError{Method: method, Code: out.Error.Code, Message: out.Error.Message}
	}
	return out.Result, nil
}

func unwrapCtxErr(ctx context.Context, err error) error {
	if ctx.Err() != nil {
		return ctx.Err()
	}
	return err
}

// readSecret reads the RPC secret file at call time (sops may have
// rewritten it at a later activation). The value goes straight onto the
// wire and into no struct that could log it.
func readSecret(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("secret file: %w", err)
	}
	s := strings.TrimSpace(string(b))
	if s == "" {
		return "", errors.New("secret file: empty")
	}
	return s, nil
}

// submit wraps call with the submit-time retry policy from
// aria2-rpc.sh: TRANSPORT failures retried with exponential backoff;
// JSON-RPC errors (hard results) and local errors (unreadable torrent)
// returned immediately.
func (c *Client) submit(ctx context.Context, method string, params ...any) (json.RawMessage, error) {
	var lastErr error
	for attempt := 0; attempt <= c.SubmitRetries; attempt++ {
		if attempt > 0 {
			select {
			case <-time.After(c.RetryBackoff * time.Duration(1<<(attempt-1))):
			case <-ctx.Done():
				return nil, &TransportError{Method: method, Err: ctx.Err()}
			}
		}
		res, err := c.call(ctx, method, c.SubmitTimeout, params...)
		if err == nil {
			return res, nil
		}
		var rpcErr *RPCError
		if errors.As(err, &rpcErr) {
			return nil, err // hard result: never retried
		}
		var te *TransportError
		if !errors.As(err, &te) {
			return nil, err // local error (e.g. unreadable torrent): no retry
		}
		lastErr = err
		if c.log != nil {
			c.log.Printf("aria2: transient failure for %s (attempt %d/%d): %v",
				method, attempt+1, c.SubmitRetries+1, te.Err)
		}
	}
	return nil, lastErr
}

// ---- queue / stat queries (fail fast, no retry) --------------------------

// TellActive returns the daemon's active downloads.
func (c *Client) TellActive(ctx context.Context) ([]Download, error) {
	res, err := c.call(ctx, "aria2.tellActive", c.QueryTimeout, queueKeys)
	if err != nil {
		return nil, err
	}
	return decodeDownloads(res, "aria2.tellActive")
}

// TellWaiting returns up to num waiting downloads from offset.
func (c *Client) TellWaiting(ctx context.Context, offset, num int) ([]Download, error) {
	res, err := c.call(ctx, "aria2.tellWaiting", c.QueryTimeout, offset, num, queueKeys)
	if err != nil {
		return nil, err
	}
	return decodeDownloads(res, "aria2.tellWaiting")
}

// TellStopped returns up to num stopped (complete/error/removed)
// downloads from offset.
func (c *Client) TellStopped(ctx context.Context, offset, num int) ([]Download, error) {
	res, err := c.call(ctx, "aria2.tellStopped", c.QueryTimeout, offset, num, queueKeys)
	if err != nil {
		return nil, err
	}
	return decodeDownloads(res, "aria2.tellStopped")
}

// GetGlobalStat returns the daemon-wide queue counters.
func (c *Client) GetGlobalStat(ctx context.Context) (GlobalStat, error) {
	res, err := c.call(ctx, "aria2.getGlobalStat", c.QueryTimeout)
	if err != nil {
		return GlobalStat{}, err
	}
	var gs GlobalStat
	if err := json.Unmarshal(res, &gs); err != nil {
		return GlobalStat{}, &TransportError{Method: "aria2.getGlobalStat", Err: errors.New("malformed result")}
	}
	return gs, nil
}

// GetVersion returns the daemon's version + feature list.
func (c *Client) GetVersion(ctx context.Context) (Version, error) {
	res, err := c.call(ctx, "aria2.getVersion", c.QueryTimeout)
	if err != nil {
		return Version{}, err
	}
	var v Version
	if err := json.Unmarshal(res, &v); err != nil {
		return Version{}, &TransportError{Method: "aria2.getVersion", Err: errors.New("malformed result")}
	}
	return v, nil
}

// ---- controls (no retry: they answer fast or the daemon is wedged) ----

// Pause pauses the download gid (graceful aria2.pause, like the rest of
// the fleet's client — not forcePause).
func (c *Client) Pause(ctx context.Context, gid string) error {
	_, err := c.call(ctx, "aria2.pause", c.QueryTimeout, gid)
	return err
}

// Unpause resumes a paused download.
func (c *Client) Unpause(ctx context.Context, gid string) error {
	_, err := c.call(ctx, "aria2.unpause", c.QueryTimeout, gid)
	return err
}

// Remove removes a download from the queue (partial files stay on disk —
// the same resume semantics the acquire oneshot relies on).
func (c *Client) Remove(ctx context.Context, gid string) error {
	_, err := c.call(ctx, "aria2.remove", c.QueryTimeout, gid)
	return err
}

// ---- submissions ---------------------------------------------------------

// AddURI submits an HTTP(S)/FTP/... download and returns its gid.
func (c *Client) AddURI(ctx context.Context, uris []string, o Options) (string, error) {
	res, err := c.submit(ctx, "aria2.addUri", uris, map[string]any(o))
	if err != nil {
		return "", err
	}
	var gid string
	if err := json.Unmarshal(res, &gid); err != nil {
		return "", &TransportError{Method: "aria2.addUri", Err: errors.New("malformed result")}
	}
	return gid, nil
}

// AddTorrent submits the .torrent at torrentFile and returns its gid.
// The EMPTY uris array is load-bearing (aria2 issue #2075: the options
// struct is ignored without it) — params are [token, b64, [], options].
func (c *Client) AddTorrent(ctx context.Context, torrentFile string, o Options) (string, error) {
	raw, err := os.ReadFile(torrentFile)
	if err != nil {
		return "", fmt.Errorf("aria2: read torrent %s: %w", filepath.Base(torrentFile), err)
	}
	b64 := base64.StdEncoding.EncodeToString(raw)
	res, err := c.submit(ctx, "aria2.addTorrent", b64, []string{}, map[string]any(o))
	if err != nil {
		return "", err
	}
	var gid string
	if err := json.Unmarshal(res, &gid); err != nil {
		return "", &TransportError{Method: "aria2.addTorrent", Err: errors.New("malformed result")}
	}
	return gid, nil
}

// AcquireTorrentOptions builds the per-system submission options the
// acquire action uses — the exact semantics of aria2-rpc.sh
// submit-torrent, ported:
//
//   - dir routes the download into <incomingDir>/<sys> (aria2 creates
//     it at download start, owned by the daemon user — the same
//     ownership rom-acquire's install -d achieves);
//   - seed-time=0: bulk ROM sets are staged, not seeded (the daemon's
//     global default is 60m);
//   - allow-overwrite=true: re-staging over the existing tree;
//   - check-integrity only when the .aria2 control file is ABSENT: a
//     present control file holds authoritative piece state, so re-hashing
//     the whole staged tree would be pure wasted I/O on multi-GB sets;
//     without it, aria2 hash-verifies existing chunks and fetches only
//     the missing pieces (partial data still resumes in place).
func AcquireTorrentOptions(incomingDir, sys string) Options {
	dir := filepath.Join(incomingDir, sys)
	return Options{
		"dir":             dir,
		"seed-time":       "0",
		"allow-overwrite": "true",
		"check-integrity": !hasAria2ControlFile(dir),
	}
}

// hasAria2ControlFile reports whether any *.aria2 control file exists
// under dir (aria2-rpc.sh's `find "$dir" -name '*.aria2' -print -quit`).
// An absent/unreadable dir yields false — the safe default (hash-check).
func hasAria2ControlFile(dir string) bool {
	found := false
	_ = filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return nil // unreadable entries skipped, like find 2>/dev/null
		}
		if !d.IsDir() && strings.HasSuffix(d.Name(), ".aria2") {
			found = true
			return filepath.SkipAll
		}
		return nil
	})
	return found
}

// decodeDownloads parses a tell* result into []Download.
func decodeDownloads(res json.RawMessage, method string) ([]Download, error) {
	var raws []rawDownload
	if err := json.Unmarshal(res, &raws); err != nil {
		return nil, &TransportError{Method: method, Err: errors.New("malformed result")}
	}
	out := make([]Download, 0, len(raws))
	for _, r := range raws {
		out = append(out, Download{
			GID:             r.GID,
			Status:          r.Status,
			TotalLength:     int64(r.TotalLength),
			CompletedLength: int64(r.CompletedLength),
			DownloadSpeed:   int64(r.DownloadSpeed),
			UploadSpeed:     int64(r.UploadSpeed),
			Dir:             r.Dir,
			ErrorMessage:    r.ErrorMessage,
			BitTorrent:      r.BitTorrent,
			Files:           r.Files,
		})
	}
	return out, nil
}
