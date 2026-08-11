// suno-backup mirrors a Suno account's track library — lossless WAV masters
// plus the complete per-clip metadata object — into a local directory tree on
// europa's tank/archive/suno dataset.
//
// Suno ships no official API. This daemon replays the browser session against
// the same internal endpoints the suno.com web app uses (discovered against the
// app's own JS bundle + the gcui-art/suno-api reference):
//
//   - Auth: the long-lived Clerk __client cookie (a refresh JWT, ~1yr) is
//     carried to https://auth.suno.com/v1/client, which returns the active
//     session id. The session is kept alive with hourly POSTs to
//     /v1/client/sessions/<sid>/tokens that mint a fresh 1-hour access JWT
//     (audience "suno-api"). The __client value is sent as the raw
//     Authorization header value (NO "Bearer " prefix) on the Clerk calls —
//     Clerk's own convention — while the Suno API calls use a normal
//     "Authorization: Bearer <access-jwt>".
//   - Library: GET https://studio-api.prod.suno.com/api/feed/v2?page=N returns
//     the user's clips newest-first (20/page). The COMPLETE clip object is
//     stored verbatim as meta.json, so every field Suno exposes is captured:
//     lyrics live in metadata.prompt, the text prompt in
//     metadata.gpt_description_prompt, plus tags, negative_tags, duration,
//     model_name, model_badges, control_sliders, project, albums, all the
//     play/upvote/comment counts and is_public/is_trashed flags,
//     media_urls, action_config, etc.
//   - WAV: clip.audio_url is the static mp3; WAV is the lossless master and is
//     generated on demand. POST /api/gen/<id>/convert_wav/ kicks off server-side
//     conversion, then GET /api/gen/<id>/wav_file/ is polled until it returns
//     wav_file_url, which is then streamed down (a signed cdn1.suno.ai/<id>.wav).
//
// Reads are NOT captcha-gated (only generation is), so no browser/captcha
// solving is required. Everything is rate-limited and resumable: an index
// (clip id -> record) and a backfill cursor (page number) are persisted after
// every successful backup, so restarts resume without re-work.
//
// Two loops run concurrently:
//   - recent scan: every --interval, walk the newest --recent-pages and back up
//     anything not yet indexed (catches freshly generated tracks quickly).
//   - backfill: continuously advance the page cursor through history
//     (--backfill-step pages per pass), backing up every clip not yet indexed,
//     until an empty page is reached (then it idles and the recent scan owns
//     the steady state). 23k+ tracks at server-side ~30s/clip conversion is a
//     multi-day one-time backfill; it progresses resumably and never blocks the
//     recent scan.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	appName = "suno-backup"

	clerkBase     = "https://auth.suno.com"
	clerkAPIVer   = "2025-11-10"
	clerkJSVer    = "5.117.0"
	apiBase       = "https://studio-api.prod.suno.com"
	defaultUA     = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
	sunoClientHdr = "Android prerelease-4nt180t 1.0.42"

	tokenRefreshSkew = 5 * time.Minute
	apiTimeout       = 60 * time.Second
	downloadTimeout  = 10 * time.Minute
)

type config struct {
	cookiePath     string
	dataDir        string
	recentPages    int
	backfillStep   int
	concurrency    int
	interval       time.Duration
	pollInterval   time.Duration
	convertTimeout time.Duration
}

func loadConfig(log *slog.Logger) config {
	geti := func(k string, def int) int {
		if s := os.Getenv(k); s != "" {
			if v, err := strconv.Atoi(s); err == nil {
				return v
			}
		}
		return def
	}
	getd := func(k string, def time.Duration) time.Duration {
		if s := os.Getenv(k); s != "" {
			if d, err := time.ParseDuration(s); err == nil {
				return d
			}
		}
		return def
	}
	cfg := config{
		cookiePath:     envOr("SUNO_COOKIE_PATH", "/run/secrets/suno_cookie"),
		dataDir:        envOr("SUNO_DATA_DIR", "/tank/archive/suno"),
		recentPages:    geti("SUNO_RECENT_PAGES", 10),
		backfillStep:   geti("SUNO_BACKFILL_STEP", 25),
		concurrency:    geti("SUNO_CONCURRENCY", 3),
		interval:       getd("SUNO_INTERVAL", 30*time.Minute),
		pollInterval:   getd("SUNO_POLL_INTERVAL", 5*time.Second),
		convertTimeout: getd("SUNO_CONVERT_TIMEOUT", 3*time.Minute),
	}
	log.Info("config loaded",
		"data_dir", cfg.dataDir, "recent_pages", cfg.recentPages,
		"backfill_step", cfg.backfillStep, "concurrency", cfg.concurrency,
		"interval", cfg.interval)
	return cfg
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// ----------------------------- Auth (Clerk) ---------------------------------

type auth struct {
	http      *http.Client
	cookieVal string // the __client refresh JWT value, verbatim
	log       *slog.Logger

	mu       sync.Mutex
	sid      string
	token    string
	tokenExp time.Time
}

func newAuth(httpc *http.Client, cookieVal string, log *slog.Logger) *auth {
	return &auth{http: httpc, cookieVal: cookieVal, log: log}
}

// clerkReq builds a request to auth.suno.com carrying the __client value as
// the raw Authorization header (Clerk's convention — no "Bearer ") and as the
// matching cookie, exactly like the suno.com frontend.
func (a *auth) clerkReq(ctx context.Context, method, rawURL string) (*http.Request, error) {
	req, err := http.NewRequestWithContext(ctx, method, rawURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", a.cookieVal)
	req.Header.Set("Cookie", "__client="+a.cookieVal)
	req.Header.Set("User-Agent", defaultUA)
	return req, nil
}

// getAuthToken establishes the session id and an initial access token by
// reading the client object. Idempotent; safe to call on every cold start.
func (a *auth) getAuthToken(ctx context.Context) error {
	u := fmt.Sprintf("%s/v1/client?__clerk_api_version=%s&_clerk_js_version=%s",
		clerkBase, clerkAPIVer, clerkJSVer)
	req, err := a.clerkReq(ctx, http.MethodGet, u)
	if err != nil {
		return err
	}
	resp, err := a.http.Do(req)
	if err != nil {
		return fmt.Errorf("clerk /v1/client: %w", err)
	}
	defer resp.Body.Close()
	var body struct {
		Response struct {
			LastActiveSessionID string `json:"last_active_session_id"`
			Sessions            []struct {
				LastActiveToken struct {
					JWT string `json:"jwt"`
				} `json:"last_active_token"`
			} `json:"sessions"`
		} `json:"response"`
		Errors []struct {
			Message string `json:"message"`
		} `json:"errors"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return fmt.Errorf("clerk /v1/client decode (status %d): %w", resp.StatusCode, err)
	}
	if len(body.Errors) > 0 {
		return fmt.Errorf("clerk error: %s", body.Errors[0].Message)
	}
	if body.Response.LastActiveSessionID == "" {
		return errors.New("clerk returned no active session — the __client cookie is likely expired; re-extract it")
	}
	if len(body.Response.Sessions) == 0 || body.Response.Sessions[0].LastActiveToken.JWT == "" {
		return errors.New("clerk returned no active token")
	}
	jwt := body.Response.Sessions[0].LastActiveToken.JWT
	exp, err := jwtExp(jwt)
	if err != nil {
		return fmt.Errorf("decode access jwt: %w", err)
	}
	a.mu.Lock()
	a.sid = body.Response.LastActiveSessionID
	a.token = jwt
	a.tokenExp = exp
	a.mu.Unlock()
	a.log.Info("auth established", "sid", a.sid, "token_exp", exp.Format(time.RFC3339))
	return nil
}

// keepAlive mints a fresh access token by rotating the session token. Called
// when the current token is within tokenRefreshSkew of expiry.
func (a *auth) keepAlive(ctx context.Context) error {
	a.mu.Lock()
	sid := a.sid
	a.mu.Unlock()
	if sid == "" {
		return a.getAuthToken(ctx)
	}
	u := fmt.Sprintf("%s/v1/client/sessions/%s/tokens?__clerk_api_version=%s&_clerk_js_version=%s",
		clerkBase, sid, clerkAPIVer, clerkJSVer)
	req, err := a.clerkReq(ctx, http.MethodPost, u)
	if err != nil {
		return err
	}
	resp, err := a.http.Do(req)
	if err != nil {
		return fmt.Errorf("clerk tokens: %w", err)
	}
	defer resp.Body.Close()
	var body struct {
		JWT    string `json:"jwt"`
		Errors []struct {
			Message string `json:"message"`
		} `json:"errors"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return fmt.Errorf("clerk tokens decode (status %d): %w", resp.StatusCode, err)
	}
	if len(body.Errors) > 0 {
		return fmt.Errorf("clerk tokens error: %s", body.Errors[0].Message)
	}
	if body.JWT == "" {
		return errors.New("clerk tokens returned no jwt")
	}
	exp, err := jwtExp(body.JWT)
	if err != nil {
		return fmt.Errorf("decode rotated jwt: %w", err)
	}
	a.mu.Lock()
	a.token = body.JWT
	a.tokenExp = exp
	a.mu.Unlock()
	return nil
}

// tokenFor returns a currently-valid access token, refreshing first if needed.
func (a *auth) tokenFor(ctx context.Context) (string, error) {
	a.mu.Lock()
	hasToken := a.token != ""
	fresh := time.Now().Add(tokenRefreshSkew).Before(a.tokenExp)
	exp := a.tokenExp
	a.mu.Unlock()
	if hasToken && fresh {
		return a.token, nil
	}
	a.log.Info("refreshing access token", "stale_at", exp.Format(time.RFC3339))
	if err := a.keepAlive(ctx); err != nil {
		// Fall back to a full re-init (handles a rotated/lost session id).
		a.log.Warn("keepAlive failed, re-initializing auth", "err", err)
		if err := a.getAuthToken(ctx); err != nil {
			return "", err
		}
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.token, nil
}

// jwtExp decodes the `exp` claim of an unsigned-verified JWT (we trust the
// transport here; Suno signs it, we just read the expiry).
func jwtExp(jwt string) (time.Time, error) {
	parts := strings.Split(jwt, ".")
	if len(parts) < 2 {
		return time.Time{}, errors.New("not a jwt")
	}
	payload, err := base64urlDecode(parts[1])
	if err != nil {
		return time.Time{}, err
	}
	var claims struct {
		Exp int64 `json:"exp"`
	}
	if err := json.Unmarshal(payload, &claims); err != nil {
		return time.Time{}, err
	}
	if claims.Exp == 0 {
		return time.Time{}, errors.New("no exp claim")
	}
	return time.Unix(claims.Exp, 0), nil
}

func base64urlDecode(s string) ([]byte, error) {
	if pad := len(s) % 4; pad != 0 {
		s += strings.Repeat("=", 4-pad)
	}
	return base64.StdEncoding.DecodeString(strings.ReplaceAll(strings.ReplaceAll(s, "-", "+"), "_", "/"))
}

// ------------------------------- API client ---------------------------------

type apiClient struct {
	http *http.Client
	auth *auth
	log  *slog.Logger
}

func (c *apiClient) doGet(ctx context.Context, url string, out any) error {
	tok, err := c.auth.tokenFor(ctx)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("User-Agent", defaultUA)
	req.Header.Set("x-suno-client", sunoClientHdr)
	req.Header.Set("Origin", "https://suno.com")
	req.Header.Set("Referer", "https://suno.com/")
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("GET %s: status %d: %s", url, resp.StatusCode, strings.TrimSpace(string(b)))
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

func (c *apiClient) doPost(ctx context.Context, url string) error {
	tok, err := c.auth.tokenFor(ctx)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("User-Agent", defaultUA)
	req.Header.Set("x-suno-client", sunoClientHdr)
	req.Header.Set("Origin", "https://suno.com")
	req.Header.Set("Referer", "https://suno.com/")
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	// 204 No Content is the happy path for convert_wav.
	if resp.StatusCode >= 300 && resp.StatusCode != http.StatusNoContent {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("POST %s: status %d: %s", url, resp.StatusCode, strings.TrimSpace(string(b)))
	}
	return nil
}

type feedPage struct {
	Clips           []json.RawMessage `json:"clips"`
	HasMore         bool              `json:"has_more"`
	CurrentPage     int               `json:"current_page"`
	NumTotalResults int               `json:"num_total_results"`
}

func (c *apiClient) fetchPage(ctx context.Context, page int) (feedPage, error) {
	u := fmt.Sprintf("%s/api/feed/v2?page=%d", apiBase, page)
	var fp feedPage
	if err := c.doGet(ctx, u, &fp); err != nil {
		return feedPage{}, err
	}
	return fp, nil
}

// clipCore carries only the fields needed to route a clip; the FULL object is
// persisted verbatim as meta.json.
type clipCore struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	CreatedAt string `json:"created_at"`
	Status    string `json:"status"`
	IsTrashed bool   `json:"is_trashed"`
}

func parseCore(raw json.RawMessage) (clipCore, error) {
	var c clipCore
	err := json.Unmarshal(raw, &c)
	return c, err
}

type wavFileResp struct {
	WavFileURL string `json:"wav_file_url"`
}

// wavURL returns a ready-to-download WAV url for the clip, generating it
// server-side first if needed (POST convert_wav, then poll wav_file).
func (c *apiClient) wavURL(ctx context.Context, id string, poll, timeout time.Duration) (string, error) {
	var wf wavFileResp
	if err := c.doGet(ctx, fmt.Sprintf("%s/api/gen/%s/wav_file/", apiBase, id), &wf); err != nil {
		return "", err
	}
	if wf.WavFileURL != "" {
		return wf.WavFileURL, nil
	}
	c.log.Info("requesting wav conversion", "id", id)
	if err := c.doPost(ctx, fmt.Sprintf("%s/api/gen/%s/convert_wav/", apiBase, id)); err != nil {
		return "", err
	}
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-time.After(poll):
		}
		wf = wavFileResp{}
		if err := c.doGet(ctx, fmt.Sprintf("%s/api/gen/%s/wav_file/", apiBase, id), &wf); err != nil {
			c.log.Warn("wav_file poll error (will retry)", "id", id, "err", err)
			continue
		}
		if wf.WavFileURL != "" {
			return wf.WavFileURL, nil
		}
	}
	return "", fmt.Errorf("wav conversion timed out after %s for %s", timeout, id)
}

// ------------------------------- Store --------------------------------------

type clipRecord struct {
	ID          string `json:"id"`
	Title       string `json:"title"`
	CreatedAt   string `json:"created_at"`
	SHA256      string `json:"sha256"` // lossless WAV master
	WavBytes    int64  `json:"wav_bytes"`
	ImageSHA256 string `json:"image_sha256,omitempty"` // large cover art; "none" = checked, no art
	ImageBytes  int64  `json:"image_bytes,omitempty"`
	BackedUpAt  string `json:"backed_up_at"`
}

type storeState struct {
	Index        map[string]clipRecord `json:"index"`
	BackfillPage int                   `json:"backfill_page"`
	BackfillDone bool                  `json:"backfill_done"`
}

type store struct {
	mu   sync.Mutex
	path string
	st   storeState
}

func loadStore(path string) (*store, error) {
	s := &store{path: path, st: storeState{Index: map[string]clipRecord{}}}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	if len(data) == 0 {
		return s, nil
	}
	if err := json.Unmarshal(data, &s.st); err != nil {
		// A corrupt index would otherwise brick the daemon. Preserve the bad
		// file for forensics and start empty: the per-clip self-heal in
		// backupClip (re-derive sha256 from any wav already on disk) rebuilds
		// the index from existing files without re-downloading anything.
		// Recovery = re-walking feed pages and re-hashing local wavs, never
		// re-fetching from Suno. (tank/archive/suno is also sanoid-snapshotted
		// daily, so a clean rollback is another option.)
		rotted := path + ".corrupt-" + time.Now().UTC().Format("20060102T150405Z")
		_ = os.Rename(path, rotted)
		return s, nil
	}
	if s.st.Index == nil {
		s.st.Index = map[string]clipRecord{}
	}
	return s, nil
}

func (s *store) has(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, ok := s.st.Index[id]
	return ok
}

func (s *store) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.st.Index)
}

func (s *store) add(rec clipRecord) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.st.Index[rec.ID] = rec
}

func (s *store) cursor() (int, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.st.BackfillPage, s.st.BackfillDone
}

func (s *store) setCursor(page int, done bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.st.BackfillPage = page
	s.st.BackfillDone = done
}

func (s *store) save() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return atomicWriteJSON(s.path, s.st)
}

// ------------------------------- Daemon -------------------------------------

type daemon struct {
	cfg  config
	api  *apiClient
	st   *store
	log  *slog.Logger
	http *http.Client
	sem  chan struct{}
}

func newDaemon(cfg config, log *slog.Logger) (*daemon, error) {
	cookieVal, err := readCookie(cfg.cookiePath)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(cfg.dataDir, 0o775); err != nil {
		return nil, fmt.Errorf("mkdir data dir: %w", err)
	}
	st, err := loadStore(filepath.Join(cfg.dataDir, "index.json"))
	if err != nil {
		return nil, err
	}
	httpc := &http.Client{Timeout: apiTimeout}
	authc := newAuth(httpc, cookieVal, log)
	api := &apiClient{http: httpc, auth: authc, log: log}
	d := &daemon{
		cfg: cfg, api: api, st: st, log: log,
		http: &http.Client{Timeout: downloadTimeout},
		sem:  make(chan struct{}, cfg.concurrency),
	}
	return d, nil
}

func readCookie(path string) (string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read cookie secret %s: %w", path, err)
	}
	// The sops secret may hold either a bare __client JWT value, or a full
	// "Cookie:" header / "key=value" pair. Extract the __client value.
	s := strings.TrimSpace(string(raw))
	if v := extractCookieValue(s, "__client"); v != "" {
		return v, nil
	}
	if !strings.ContainsAny(s, " \t;=") {
		return s, nil // bare token
	}
	return "", fmt.Errorf("cookie file %s has no __client value", path)
}

// extractCookieValue pulls a named cookie out of either "name=value", a full
// "k=v; k2=v2" cookie header, or newline-separated "k=v\nk2=v2". Returns "" if
// not found.
func extractCookieValue(header, name string) string {
	header = strings.ReplaceAll(header, "\n", ";")
	for _, part := range strings.Split(header, ";") {
		part = strings.TrimSpace(part)
		if strings.HasPrefix(part, name+"=") {
			return strings.TrimPrefix(part, name+"=")
		}
	}
	return ""
}

// backupClip persists the verbatim clip object as meta.json, then acquires the
// lossless WAV (generating it on demand) and records it in the index.
func (d *daemon) backupClip(ctx context.Context, raw json.RawMessage, core clipCore) error {
	dir := filepath.Join(d.cfg.dataDir, "tracks", yearMonth(core.CreatedAt), core.ID)
	if err := os.MkdirAll(dir, 0o775); err != nil {
		return err
	}

	// 1. meta.json — the complete clip object, pretty-printed. The full set of
	//    metadata Suno exposes (lyrics, prompts, tags, counts, flags, project,
	//    media_urls, action_config, ...), stored verbatim so nothing is lost to
	//    a hand-picked struct. Also the source healImages reads for the cover
	//    URL when backfilling already-indexed clips (no API call).
	metaPath := filepath.Join(dir, "meta.json")
	if _, err := os.Stat(metaPath); errors.Is(err, os.ErrNotExist) {
		if err := atomicWriteBytes(metaPath, prettyJSON(raw)); err != nil {
			return fmt.Errorf("write meta.json: %w", err)
		}
	} else if err != nil {
		return err
	}

	// 2. WAV master (critical) — generate on demand and stream down atomically,
	//    or self-heal from an existing file. Never re-downloads.
	wsha, wbytes, err := d.ensureWav(ctx, core, dir)
	if err != nil {
		_ = os.Remove(metaPath) // roll back meta so next pass retries cleanly
		return err
	}

	// 3. Large cover art (image_large_url) — supplementary. A clip with no
	//    cover URL records the "none" sentinel so healImages doesn't keep
	//    re-scanning it; a download failure leaves ImageSHA256 empty for a
	//    healImages retry.
	isha, ibytes, ierr := d.ensureImage(ctx, raw, dir)
	switch {
	case errors.Is(ierr, errCoverUnavailable):
		isha = "none" // large cover permanently refused (4xx) — don't retry
		d.log.Info("cover marked unavailable", "id", core.ID)
	case ierr != nil:
		// Transient (5xx/network) — leave empty so healImages retries.
		d.log.Warn("cover art fetch failed (healImages will retry)", "id", core.ID, "err", ierr)
	case isha == "":
		isha = "none" // clip has no image_large_url at all; mark checked
	}

	d.st.add(clipRecord{
		ID: core.ID, Title: core.Title, CreatedAt: core.CreatedAt,
		SHA256: wsha, WavBytes: wbytes,
		ImageSHA256: isha, ImageBytes: ibytes,
		BackedUpAt: time.Now().UTC().Format(time.RFC3339),
	})
	if err := d.st.save(); err != nil {
		d.log.Error("persist index failed", "err", err)
	}
	d.log.Info("backed up", "id", core.ID, "title", core.Title,
		"wav_bytes", wbytes, "image_bytes", ibytes, "total_indexed", d.st.count())
	return nil
}

// ensureWav guarantees the lossless master is on disk, returning its sha256 and
// byte count. If the wav already exists (crash-recovery orphan, or a re-
// encounter during an index rebuild) it is hashed in place rather than
// re-fetched — never re-downloads an existing file.
func (d *daemon) ensureWav(ctx context.Context, core clipCore, dir string) (string, int64, error) {
	wavPath := filepath.Join(dir, core.ID+".wav")
	if _, err := os.Stat(wavPath); err == nil {
		sum, n, ferr := hashFile(wavPath)
		if ferr != nil {
			return "", 0, fmt.Errorf("hash existing wav %s: %w", wavPath, ferr)
		}
		return sum, n, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", 0, err
	}
	wavURL, err := d.api.wavURL(ctx, core.ID, d.cfg.pollInterval, d.cfg.convertTimeout)
	if err != nil {
		return "", 0, fmt.Errorf("wav for %s: %w", core.ID, err)
	}
	sum, n, err := d.download(ctx, wavURL, wavPath)
	if err != nil {
		return "", 0, fmt.Errorf("download %s: %w", wavURL, err)
	}
	return sum, n, nil
}

// ensureImage fetches the clip's large cover art (image_large_url) unless it is
// already on disk (hashed in place). Returns ("", 0, nil) — not an error —
// when the clip has no cover URL. Cover-art failure is non-fatal: the WAV is
// the critical artifact, and healImages retries missing covers from meta.json.
func (d *daemon) ensureImage(ctx context.Context, raw json.RawMessage, dir string) (string, int64, error) {
	imgURL := largeImageURL(raw)
	if imgURL == "" {
		return "", 0, nil
	}
	coverPath := filepath.Join(dir, "cover"+imageExt(imgURL))
	if _, err := os.Stat(coverPath); err == nil {
		sum, n, ferr := hashFile(coverPath)
		if ferr != nil {
			return "", 0, fmt.Errorf("hash existing cover %s: %w", coverPath, ferr)
		}
		return sum, n, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", 0, err
	}
	sum, n, err := d.download(ctx, imgURL, coverPath)
	if err != nil {
		if terminalHTTP(err) {
			// Permanent CDN refusal (403/404) — signal the caller to mark
			// "none" so healImages stops retrying this clip's cover forever.
			return "", 0, errCoverUnavailable
		}
		return "", 0, fmt.Errorf("cover %s: %w", imgURL, err)
	}
	return sum, n, nil
}

// largeImageURL pulls image_large_url out of the clip object (empty if absent).
func largeImageURL(raw json.RawMessage) string {
	var s struct {
		ImageLargeURL string `json:"image_large_url"`
	}
	if err := json.Unmarshal(raw, &s); err != nil {
		return ""
	}
	return strings.TrimSpace(s.ImageLargeURL)
}

// imageExt maps a cover URL to its on-disk extension. Suno serves JPEG covers
// (image_large_url is always .jpeg for real artwork), but preserve .png/.webp
// if a future/default variant ever appears rather than mislabel the file.
func imageExt(u string) string {
	switch {
	case strings.HasSuffix(u, ".png"):
		return ".png"
	case strings.HasSuffix(u, ".webp"):
		return ".webp"
	default:
		return ".jpg"
	}
}

// httpStatusError carries the HTTP response code from a failed fetch so callers
// can distinguish permanent refusals (4xx) from transient ones (5xx, network).
type httpStatusError struct{ code int }

func (e *httpStatusError) Error() string { return fmt.Sprintf("status %d", e.code) }

// terminalHTTP reports whether err is a permanent HTTP failure: 4xx other than
// 429 (Too Many Requests). Used only for the cover art — a clip whose
// image_large_url persistently 403/404s is marked "none" so healImages stops
// retrying it forever, instead of re-fetching it every hour. WAV failures are
// NEVER treated as terminal (a clip is never abandoned for a missing master).
func terminalHTTP(err error) bool {
	var h *httpStatusError
	if errors.As(err, &h) {
		return h.code >= 400 && h.code < 500 && h.code != http.StatusTooManyRequests
	}
	return false
}

// errCoverUnavailable signals that a clip's large cover is permanently
// unavailable (4xx) so the caller records the "none" sentinel rather than
// leaving the field empty for a retry that will never succeed.
var errCoverUnavailable = errors.New("cover unavailable")

// download streams url to dest atomically (.part then rename), hashing as it
// goes, returning the sha256 hex and byte count.
func (d *daemon) download(ctx context.Context, urlStr, dest string) (string, int64, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, urlStr, nil)
	if err != nil {
		return "", 0, err
	}
	req.Header.Set("User-Agent", defaultUA)
	resp, err := d.http.Do(req)
	if err != nil {
		return "", 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return "", 0, &httpStatusError{code: resp.StatusCode}
	}
	part := dest + ".part"
	f, err := os.Create(part)
	if err != nil {
		return "", 0, err
	}
	h := sha256.New()
	mw := io.MultiWriter(f, h)
	n, err := io.Copy(mw, resp.Body)
	// fsync the data before close+rename so a crash/power-loss can't leave a
	// renamed wav with only part of its bytes flushed (ZFS's COW already makes
	// this safe, but this is cheap insurance on any filesystem).
	syncErr := f.Sync()
	closeErr := f.Close()
	if err != nil {
		_ = os.Remove(part)
		return "", 0, err
	}
	if syncErr != nil {
		_ = os.Remove(part)
		return "", 0, fmt.Errorf("fsync %s: %w", part, syncErr)
	}
	if closeErr != nil {
		_ = os.Remove(part)
		return "", 0, closeErr
	}
	if n == 0 {
		_ = os.Remove(part)
		return "", 0, errors.New("empty body")
	}
	if err := os.Rename(part, dest); err != nil {
		_ = os.Remove(part)
		return "", 0, err
	}
	return hex.EncodeToString(h.Sum(nil)), n, nil
}

// hashFile streams a file through sha256, returning the hex digest and byte
// count. Used by the self-heal path to (re)derive an index entry for a wav
// already on disk without re-downloading it.
func hashFile(path string) (string, int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	h := sha256.New()
	n, err := io.Copy(h, f)
	if err != nil {
		return "", 0, err
	}
	return hex.EncodeToString(h.Sum(nil)), n, nil
}

// processClips backs up every not-yet-indexed clip in the page, concurrency-
// limited by the semaphore. Skips anything already in the index.
func (d *daemon) processClips(ctx context.Context, clips []json.RawMessage, label string) {
	type job struct {
		raw  json.RawMessage
		core clipCore
	}
	var jobs []job
	for _, raw := range clips {
		core, err := parseCore(raw)
		if err != nil || core.ID == "" {
			d.log.Warn("skipping unparseable clip", "err", err)
			continue
		}
		if d.st.has(core.ID) {
			continue
		}
		jobs = append(jobs, job{raw: raw, core: core})
	}
	if len(jobs) == 0 {
		return
	}
	d.log.Info("backing up clips", "label", label, "new", len(jobs))
	var wg sync.WaitGroup
	for _, j := range jobs {
		select {
		case <-ctx.Done():
			return
		case d.sem <- struct{}{}:
		}
		wg.Add(1)
		go func(j job) {
			defer wg.Done()
			defer func() { <-d.sem }()
			if err := d.backupClip(ctx, j.raw, j.core); err != nil {
				d.log.Warn("backup failed (will retry next pass)", "id", j.core.ID, "err", err)
			}
		}(j)
	}
	wg.Wait()
}

// scanRecent walks the newest cfg.recentPages and backs up anything new. Catches
// freshly generated tracks within one cycle.
func (d *daemon) scanRecent(ctx context.Context) {
	for page := 1; page <= d.cfg.recentPages; page++ {
		fp, err := d.api.fetchPage(ctx, page)
		if err != nil {
			d.log.Warn("recent fetch failed", "page", page, "err", err)
			return
		}
		d.processClips(ctx, fp.Clips, fmt.Sprintf("recent p%d", page))
		if len(fp.Clips) == 0 {
			return
		}
		select {
		case <-ctx.Done():
			return
		default:
		}
	}
}

// backfill advances the persisted page cursor through history, one bounded
// pass per call, until an empty page is reached (then the cursor resets and
// the steady-state is owned by scanRecent).
func (d *daemon) backfill(ctx context.Context) {
	page, done := d.st.cursor()
	if done {
		// Idle: occasionally re-walk from the top to catch stragglers that
		// shifted pages as new tracks were generated.
		page = 1
	}
	for i := 0; i < d.cfg.backfillStep; i++ {
		select {
		case <-ctx.Done():
			return
		default:
		}
		fp, err := d.api.fetchPage(ctx, page)
		if err != nil {
			d.log.Warn("backfill fetch failed", "page", page, "err", err)
			return
		}
		if len(fp.Clips) == 0 {
			d.log.Info("backfill reached end of library — complete", "last_page", page,
				"indexed", d.st.count(), "total_reported", fp.NumTotalResults)
			d.st.setCursor(1, true)
			_ = d.st.save()
			return
		}
		d.processClips(ctx, fp.Clips, fmt.Sprintf("backfill p%d", page))
		page++
		d.st.setCursor(page, false)
		_ = d.st.save()
		// Politeness: gentle spacing between feed pages.
		select {
		case <-ctx.Done():
			return
		case <-time.After(2 * time.Second):
		}
	}
	d.log.Info("backfill pass done", "next_page", page, "indexed", d.st.count())
}

func (d *daemon) run(ctx context.Context) error {
	if err := d.api.auth.getAuthToken(ctx); err != nil {
		return fmt.Errorf("initial auth: %w", err)
	}
	d.log.Info("library size reported on first page", "total", "n/a (paged)")

	// Recent scan runs immediately, then on every tick.
	go func() {
		t := time.NewTicker(d.cfg.interval)
		defer t.Stop()
		d.scanRecent(ctx)
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				d.scanRecent(ctx)
			}
		}
	}()

	// Image backfill runs immediately, then hourly. Catches clips backed up
	// before cover-art support landed and clips whose cover download failed:
	// it reads each clip's on-disk meta.json for image_large_url (no API call)
	// and fetches the large cover. Cheap no-op scan once every clip is done.
	go func() {
		t := time.NewTicker(time.Hour)
		defer t.Stop()
		d.healImages(ctx)
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				d.healImages(ctx)
			}
		}
	}()

	// Backfill runs continuously; when the library is fully walked it idles to
	// a slow re-verify sweep.
	idle := time.NewTimer(0)
	defer idle.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-idle.C:
			before := d.st.count()
			d.backfill(ctx)
			after := d.st.count()
			_, done := d.st.cursor()
			// If a pass made no progress and backfill is complete, idle longer.
			delay := 5 * time.Minute
			if done && before == after {
				delay = time.Hour
			}
			idle.Reset(delay)
		}
	}
}

// healImages backfills the large cover art for indexed clips missing it: clips
// backed up before cover-art support landed, and clips whose cover download
// previously failed. It reads each clip's on-disk meta.json for image_large_url
// — no API calls — fetches the cover, and records sha256/bytes. The "none"
// sentinel marks clips with no cover URL so they're not re-scanned. Idempotent
// and concurrency-limited; a cheap no-op scan once every clip is done.
func (d *daemon) healImages(ctx context.Context) {
	type pending struct {
		id  string
		rec clipRecord
	}
	d.st.mu.Lock()
	pend := make([]pending, 0)
	for id, rec := range d.st.st.Index {
		if rec.ImageSHA256 == "" {
			pend = append(pend, pending{id: id, rec: rec})
		}
	}
	d.st.mu.Unlock()
	if len(pend) == 0 {
		return
	}
	d.log.Info("image backfill pass", "clips_missing_cover", len(pend))
	var wg sync.WaitGroup
	for _, p := range pend {
		select {
		case <-ctx.Done():
			return
		case d.sem <- struct{}{}:
		}
		wg.Add(1)
		go func(p pending) {
			defer wg.Done()
			defer func() { <-d.sem }()
			if err := d.healOneImage(ctx, p.id, p.rec); err != nil {
				d.log.Warn("image backfill item failed (will retry)", "id", p.id, "err", err)
			}
		}(p)
	}
	wg.Wait()
}

// healOneImage fetches (or re-hashes) the large cover for one indexed clip from
// its on-disk meta.json. Marks "none" if the clip has no cover URL.
func (d *daemon) healOneImage(ctx context.Context, id string, rec clipRecord) error {
	dir := filepath.Join(d.cfg.dataDir, "tracks", yearMonth(rec.CreatedAt), id)
	raw, err := os.ReadFile(filepath.Join(dir, "meta.json"))
	if err != nil {
		return fmt.Errorf("read meta.json: %w", err)
	}
	imgURL := largeImageURL(raw)
	if imgURL == "" {
		rec.ImageSHA256 = "none"
		d.st.add(rec)
		_ = d.st.save()
		return nil
	}
	coverPath := filepath.Join(dir, "cover"+imageExt(imgURL))
	var sum string
	var n int64
	if _, err := os.Stat(coverPath); err == nil {
		sum, n, err = hashFile(coverPath)
		if err != nil {
			return err
		}
	} else {
		sum, n, err = d.download(ctx, imgURL, coverPath)
		if err != nil {
			if terminalHTTP(err) {
				// Permanent CDN refusal — stop retrying this clip hourly.
				rec.ImageSHA256 = "none"
				d.st.add(rec)
				_ = d.st.save()
				d.log.Info("cover marked unavailable", "id", id, "err", err)
				return nil
			}
			return err
		}
	}
	rec.ImageSHA256 = sum
	rec.ImageBytes = n
	d.st.add(rec)
	_ = d.st.save()
	d.log.Info("image backfilled", "id", id, "bytes", n)
	return nil
}

// ------------------------------- helpers ------------------------------------

func yearMonth(iso string) string {
	// created_at looks like "2026-08-10T11:37:00.110Z". Shard by YYYY/MM so no
	// single directory grows unbounded across a 20k+ library.
	if len(iso) >= 7 {
		y := iso[0:4]
		m := iso[5:7]
		if y != "" && m != "" {
			return filepath.Join(y, m)
		}
	}
	return filepath.Join("unknown", "unknown")
}

func prettyJSON(raw json.RawMessage) []byte {
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return raw
	}
	out, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return raw
	}
	return out
}

func atomicWriteBytes(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o775); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		_ = os.Remove(tmpName)
		return err
	}
	// fsync before close+rename so index.json / meta.json are durable across a
	// crash (the per-track index is the daemon's resume checkpoint — losing it
	// to a power-cut between write and rename would mean re-walking feeds to
	// rebuild it, never re-download, but we'd rather not).
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		_ = os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	if err := os.Chmod(tmpName, 0o644); err != nil {
		_ = os.Remove(tmpName)
		return err
	}
	return os.Rename(tmpName, path)
}

func atomicWriteJSON(path string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return atomicWriteBytes(path, data)
}

// ------------------------------- main ---------------------------------------

func main() {
	log := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	log.Info(appName + " starting")

	cfg := loadConfig(log)

	d, err := newDaemon(cfg, log)
	if err != nil {
		log.Error("init failed", "err", err)
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if err := d.run(ctx); err != nil && !errors.Is(err, context.Canceled) {
		log.Error("daemon exited with error", "err", err)
		os.Exit(1)
	}
	log.Info(appName+" shutting down", "indexed", d.st.count())
}
