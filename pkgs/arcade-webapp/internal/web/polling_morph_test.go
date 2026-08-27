// Polling morph regression: every polling/action response IS the panel
// element itself (single root carrying the panel id), so every swap
// against it must be OUTER-style — hx-swap="morph:outerHTML" via the
// vendored idiomorph extension. An inner-style swap nests a copy of the
// panel inside itself on every tick (duplicate ids, self-amplifying
// triggers, the DOM collapse seen 2026-08-27); a bare outerHTML swap
// re-creates the element (the original flicker). The ext lives as
// /static/idiomorph.min.js and every full-page layout carries
// hx-ext="morph" so children inherit it.
package web

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPollingUsesMorphSwap(t *testing.T) {
	srv := newTestServer(t)
	h := srv.Handler()

	checks := []struct {
		path string
		must []string
		not  []string
	}{
		{
			path: "/",
			must: []string{
				`hx-ext="morph"`,
				`/static/idiomorph.min.js`,
				`id="status-panel"`,
				`hx-trigger="every 10s"`,
				`hx-swap="morph:outerHTML"`,
				`id="system-cards"`,
				`id="downloads-summary"`,
				`hx-get="/partials/downloads-summary"`,
			},
			not: []string{
				`hx-swap="outerHTML"`,
				`hx-swap="morph:innerHTML"`,
			},
		},
		{
			path: "/verify",
			must: []string{
				`hx-ext="morph"`,
				`/static/idiomorph.min.js`,
				`id="verify-panel"`,
				`hx-trigger="every 2s"`,
				`hx-swap="morph:outerHTML"`,
				`hx-post="/verify"`,
				`hx-post="/dats/refresh"`,
			},
			not: []string{`hx-swap="outerHTML"`, `hx-swap="morph:innerHTML"`},
		},
		{
			path: "/metadata",
			must: []string{
				`hx-ext="morph"`,
				`/static/idiomorph.min.js`,
				`id="metadata-panel"`,
				`hx-swap="morph:outerHTML"`,
			},
			not: []string{`hx-swap="outerHTML"`, `hx-swap="morph:innerHTML"`},
		},
		{
			path: "/downloads",
			must: []string{
				`hx-ext="morph"`,
				`/static/idiomorph.min.js`,
				`id="downloads-panel"`,
				`hx-trigger="every 2s"`,
				`hx-swap="morph:outerHTML"`,
			},
			not: []string{`hx-swap="outerHTML"`, `hx-swap="morph:innerHTML"`},
		},
		{
			path: "/library",
			must: []string{
				`hx-ext="morph"`,
				`/static/idiomorph.min.js`,
				`hx-swap="morph:outerHTML"`,
			},
			not: []string{`hx-swap="outerHTML"`, `hx-swap="morph:innerHTML"`},
		},
	}
	for _, c := range checks {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, c.path, nil))
		if rec.Code != 200 {
			t.Fatalf("GET %s: status %d, want 200", c.path, rec.Code)
		}
		body := rec.Body.String()
		for _, m := range c.must {
			if !strings.Contains(body, m) {
				t.Errorf("GET %s: body missing %q", c.path, m)
			}
		}
		for _, n := range c.not {
			if strings.Contains(body, n) {
				t.Errorf("GET %s: body must not contain %q (morph contract regressed)", c.path, n)
			}
		}
	}
}

func TestPartialsUseMorphSwap(t *testing.T) {
	srv := newTestServer(t)
	h := srv.Handler()
	// Partials themselves must already carry morph:outerHTML so a
	// direct GET /partials/* also swaps without flicker if ever
	// navigated.
	partials := []string{"/partials/status", "/partials/systems"}
	for _, p := range partials {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, p, nil))
		if rec.Code != 200 {
			t.Fatalf("GET %s: status %d", p, rec.Code)
		}
		body := rec.Body.String()
		if !strings.Contains(body, `hx-swap="morph:outerHTML"`) {
			t.Errorf("GET %s: missing morph:outerHTML", p)
		}
		if strings.Contains(body, `hx-swap="outerHTML"`) || strings.Contains(body, `hx-swap="morph:innerHTML"`) {
			t.Errorf("GET %s: must not contain bare outerHTML or morph:innerHTML", p)
		}
	}
	// downloads-summary is static when download control is not
	// configured (no poll, no swap); verify the configured variant
	// does carry morph.
	{
		root := t.TempDir()
		ds, _ := newDownloadsServer(t, root)
		rec := httptest.NewRecorder()
		ds.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/partials/downloads-summary", nil))
		if rec.Code != 200 {
			t.Fatalf("GET /partials/downloads-summary (configured): status %d", rec.Code)
		}
		body := rec.Body.String()
		if !strings.Contains(body, `hx-swap="morph:outerHTML"`) {
			t.Error("GET /partials/downloads-summary (configured): missing morph:outerHTML")
		}
		if strings.Contains(body, `hx-swap="outerHTML"`) || strings.Contains(body, `hx-swap="morph:innerHTML"`) {
			t.Error("GET /partials/downloads-summary (configured): must not contain bare outerHTML or morph:innerHTML")
		}
	}
	// Verify/metadata partials need a pipeline — build via helper.
	vsrv, _ := newVerifyServer(t)
	for _, p := range []string{"/partials/verify"} {
		rec := httptest.NewRecorder()
		vsrv.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, p, nil))
		if rec.Code != 200 {
			t.Fatalf("GET %s: status %d", p, rec.Code)
		}
		if !strings.Contains(rec.Body.String(), `hx-swap="morph:outerHTML"`) {
			t.Errorf("GET %s: missing morph:outerHTML", p)
		}
	}
	h2 := newMetaServer(t)
	rec := httptest.NewRecorder()
	h2.srv.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/partials/metadata", nil))
	if rec.Code != 200 {
		t.Fatalf("GET /partials/metadata: %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), `hx-swap="morph:outerHTML"`) {
		t.Error("GET /partials/metadata: missing morph:outerHTML")
	}
}

// TestPartialResponseShapeMatchesTarget pins the swap CONTRACT: a
// response swapped into a panel must contain that panel's id EXACTLY
// ONCE, as the root element. inner-style swaps with self-rooted
// responses nest the panel inside itself every tick — the DOM collapse
// regression. Every polled fragment here renders the panel element
// itself, so the root check is what keeps morph:outerHTML honest.
func TestPartialResponseShapeMatchesTarget(t *testing.T) {
	cases := []struct {
		name   string
		server func(t *testing.T) http.Handler
		path   string
		panel  string
	}{
		{"status", func(t *testing.T) http.Handler { return newTestServer(t).Handler() }, "/partials/status", "status-panel"},
		{"systems", func(t *testing.T) http.Handler { return newTestServer(t).Handler() }, "/partials/systems", "system-cards"},
		{"library", func(t *testing.T) http.Handler { return newTestServer(t).Handler() }, "/partials/library", "library-grid"},
		{"summary", func(t *testing.T) http.Handler {
			root := t.TempDir()
			ds, _ := newDownloadsServer(t, root)
			return ds.Handler()
		}, "/partials/downloads-summary", "downloads-summary"},
		{"downloads", func(t *testing.T) http.Handler {
			root := t.TempDir()
			ds, _ := newDownloadsServer(t, root)
			return ds.Handler()
		}, "/partials/downloads", "downloads-panel"},
		{"verify", func(t *testing.T) http.Handler {
			v, _ := newVerifyServer(t)
			return v.Handler()
		}, "/partials/verify", "verify-panel"},
		{"metadata", func(t *testing.T) http.Handler {
			m := newMetaServer(t)
			return m.srv.Handler()
		}, "/partials/metadata", "metadata-panel"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			tc.server(t).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, tc.path, nil))
			if rec.Code != 200 {
				t.Fatalf("GET %s: status %d", tc.path, rec.Code)
			}
			body := strings.TrimSpace(rec.Body.String())
			rootTag := `<div id="` + tc.panel + `"`
			if !strings.HasPrefix(body, rootTag) {
				t.Errorf("GET %s: response root is not <%s — shape contract broken (first 80 bytes: %q)",
					tc.path, rootTag, truncateForLog(body, 80))
			}
			if n := strings.Count(body, `id="`+tc.panel+`"`); n != 1 {
				t.Errorf("GET %s: panel id %q appears %d times, want exactly 1 (nesting/duplication regression)", tc.path, tc.panel, n)
			}
		})
	}
}

// truncateForLog bounds an error string (test-log hygiene only).
func truncateForLog(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n-1] + "…"
}

func TestIdiomorphStaticServed(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/static/idiomorph.min.js", nil))
	if rec.Code != 200 {
		t.Fatalf("GET /static/idiomorph.min.js: status %d, want 200", rec.Code)
	}
	body := rec.Body.String()
	for _, m := range []string{"Idiomorph", "morph", "htmx.defineExtension"} {
		if !strings.Contains(body, m) {
			t.Errorf("idiomorph.min.js missing marker %q", m)
		}
	}
	if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, "javascript") {
		t.Errorf("idiomorph Content-Type = %q, want javascript", ct)
	}
	lic := httptest.NewRecorder()
	srv.Handler().ServeHTTP(lic, httptest.NewRequest(http.MethodGet, "/static/idiomorph-LICENSE", nil))
	if lic.Code != 200 || !strings.Contains(lic.Body.String(), "Zero-Clause BSD") {
		t.Errorf("idiomorph LICENSE = %d, missing 0BSD", lic.Code)
	}
}
