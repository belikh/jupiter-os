package web

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestSecurityHeadersOnEverySurface (remediation W4a / plan §6.F): the
// OWASP baseline set is stamped by middleware — pages, partials, static
// assets and /healthz cannot drift out from under it.
func TestSecurityHeadersOnEverySurface(t *testing.T) {
	srv := newTestServer(t)
	for _, path := range []string{"/", "/partials/status", "/static/app.css", "/healthz"} {
		rec := get(t, srv.Handler(), path)
		for _, tc := range []struct{ header, want string }{
			{"Content-Security-Policy", "default-src 'self'"},
			{"Content-Security-Policy", "script-src 'self'"},
			{"X-Frame-Options", "DENY"},
			{"X-Content-Type-Options", "nosniff"},
			{"Referrer-Policy", "no-referrer"},
		} {
			if got := rec.Header().Get(tc.header); !strings.Contains(got, tc.want) {
				t.Errorf("%s: %s = %q, want it to contain %q", path, tc.header, got, tc.want)
			}
		}
		// The CSP bans inline scripts outright — no 'unsafe-inline' in
		// script-src (styles keep it for the progressbar widths; that
		// residual is documented in hardening.go).
		csp := rec.Header().Get("Content-Security-Policy")
		scriptSrc := csp[strings.Index(csp, "script-src"):]
		if end := strings.IndexByte(scriptSrc, ';'); end >= 0 {
			scriptSrc = scriptSrc[:end]
		}
		if strings.Contains(scriptSrc, "unsafe-inline") || strings.Contains(scriptSrc, "unsafe-eval") {
			t.Errorf("%s: script-src allows unsafe-inline/eval: %q", path, scriptSrc)
		}
	}
}

// TestCrossOriginProtectionRefusesHostileBrowserPost (W4a / plan §6.F:
// "stdlib CrossOriginProtection for the CSRF posture"): a POST that a
// BROWSER declares cross-site (Sec-Fetch-Site: cross-site) is refused
// 403 by the middleware BEFORE any handler runs — the hostile-tab
// class the htmx-only header check cannot see, because a hostile page
// can send HX-Request itself. Same-site and header-less requests (the
// curl-shaped client every other test drives) pass unchanged, and a
// cross-site GET still serves read-only pages.
func TestCrossOriginProtectionRefusesHostileBrowserPost(t *testing.T) {
	srv := newTestServer(t)

	// Cross-site browser POST, smuggling the htmx header.
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/rescan", nil)
	req.Header.Set("Sec-Fetch-Site", "cross-site")
	req.Header.Set("HX-Request", "true")
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Errorf("cross-site POST /rescan = %d, want 403 (CSRF middleware must refuse it before the handler)", rec.Code)
	}

	// Same-site browser POST reaches the handler as before.
	rec2 := httptest.NewRecorder()
	req2 := httptest.NewRequest("POST", "/rescan", nil)
	req2.Header.Set("Sec-Fetch-Site", "same-origin")
	req2.Header.Set("HX-Request", "true")
	srv.Handler().ServeHTTP(rec2, req2)
	if rec2.Code == http.StatusForbidden {
		t.Errorf("same-site POST /rescan refused 403 — CrossOriginProtection must not block the app's own pages")
	}

	// A GET (safe method) is never CSRF-blocked, cross-site or not.
	rec3 := httptest.NewRecorder()
	req3 := httptest.NewRequest("GET", "/", nil)
	req3.Header.Set("Sec-Fetch-Site", "cross-site")
	srv.Handler().ServeHTTP(rec3, req3)
	if rec3.Code != http.StatusOK {
		t.Errorf("cross-site GET / = %d, want 200 (safe methods always allowed)", rec3.Code)
	}

	// The refusal still carries the security-header set (headers are
	// the OUTERMOST middleware).
	if rec.Header().Get("Content-Security-Policy") == "" {
		t.Error("CSRF-refused response lacks the security headers")
	}
}

// TestPagesServeNoInlineScripts: with the toast handler extracted to
// /static/toasts.js, no page ships a bare <script> block — the property
// the strict CSP depends on.
func TestPagesServeNoInlineScripts(t *testing.T) {
	srv := newTestServer(t)
	for _, path := range []string{"/", "/library", "/downloads", "/verify", "/metadata", "/collections"} {
		body := get(t, srv.Handler(), path).Body.String()
		for _, prohibited := range []string{"<script>", "onclick=", "onerror="} {
			if strings.Contains(body, prohibited) {
				t.Errorf("%s renders %q — inline script handlers break the strict CSP", path, prohibited)
			}
		}
		if !strings.Contains(body, `src="/static/toasts.js"`) {
			t.Errorf("%s does not load /static/toasts.js (toast handler missing)", path)
		}
	}
}

// TestHtmxConfigPinnedInEveryLayout: every full page pins htmx's
// allowEval off and stops the indicator <style> injection (plan §6.F —
// audit and pin the htmx defaults), merged into the same meta as any
// page-level responseHandling override (htmx reads only the FIRST
// htmx-config meta).
func TestHtmxConfigPinnedInEveryLayout(t *testing.T) {
	srv := newTestServer(t)
	for _, path := range []string{"/", "/library", "/downloads", "/verify", "/metadata", "/collections"} {
		body := get(t, srv.Handler(), path).Body.String()
		if !strings.Contains(body, `"allowEval":false`) {
			t.Errorf("%s: htmx-config does not pin allowEval:false", path)
		}
		if !strings.Contains(body, `"includeIndicatorStyles":false`) {
			t.Errorf("%s: htmx-config does not pin includeIndicatorStyles:false", path)
		}
	}
}

// TestBodyLimitRefusesOversizedForms (W4a): MaxBytesReader on EVERY
// body-reading endpoint — a declared Content-Length over the 1 MiB
// default cap is refused 413 before any handler runs.
func TestBodyLimitRefusesOversizedForms(t *testing.T) {
	srv := newTestServer(t)
	big := strings.Repeat("x", 2<<20) // 2 MiB > the 1 MiB default cap

	// collections create: a small-form endpoint.
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/collections/create", strings.NewReader("name="+big+"&summary=x"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("oversized /collections/create = %d, want 413", rec.Code)
	}

	// rescan: a body-less mutating endpoint still gets the reader armed.
	rec2 := httptest.NewRecorder()
	req2 := httptest.NewRequest("POST", "/rescan", strings.NewReader(big))
	req2.ContentLength = int64(len(big))
	srv.Handler().ServeHTTP(rec2, req2)
	if rec2.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("oversized /rescan = %d, want 413", rec2.Code)
	}
}

// TestBodyLimitTorrentUploadCap: the torrent upload keeps its own larger
// cap — a 100 MiB upload is refused 413 while the handler's 64 MiB
// contract stands (the middleware's cap and the handler's agree).
func TestBodyLimitTorrentUploadCap(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/systems/nes/stage-torrent", bytes.NewReader(make([]byte, 100<<20)))
	req.ContentLength = 100 << 20
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("100 MiB stage-torrent = %d, want 413", rec.Code)
	}
	// The boundary itself is exercised end-to-end in the VM harness
	// (multipart); here the route-cap routing is the unit under test.
	if limit := bodyLimitForPath(httptest.NewRequest("POST", "/systems/nes/stage-torrent", nil)); limit != maxBodyTorrentUpload {
		t.Errorf("stage-torrent cap = %d, want %d", limit, maxBodyTorrentUpload)
	}
	if limit := bodyLimitForPath(httptest.NewRequest("POST", "/collections/create", nil)); limit != maxBodyDefault {
		t.Errorf("default cap = %d, want %d", limit, maxBodyDefault)
	}
}

// TestUndeclaredBodyCapStillEnforced: a chunked body (no declared
// Content-Length) dies on the MaxBytesReader mid-parse — the handler
// sees the truncation, never a silently-accepted tail.
func TestUndeclaredBodyCapStillEnforced(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest("POST", "/collections/create", strings.NewReader("name="+strings.Repeat("y", 2<<20)+"&summary=x"))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.ContentLength = -1 // force the chunked path
	srv.Handler().ServeHTTP(rec, req)
	// The middleware lets the reader do the refusing; the collection
	// must NOT have been created from a truncated name.
	if rec.Code == http.StatusOK && strings.Contains(rec.Body.String(), "toast") {
		t.Errorf("oversized chunked create accepted: %d", rec.Code)
	}
	colls, err := srv.st.Collections()
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range colls {
		if len(c.Name) > maxBodyDefault {
			t.Errorf("collection %q survived a truncated oversize body", c.Name[:64]+"…")
		}
	}
}
