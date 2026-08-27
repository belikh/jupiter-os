// Polling morph regression: the dashboard/metadata/verify flicker fix
// swaps polling regions with hx-swap="morph:innerHTML" via the vendored
// idiomorph extension, not outerHTML/innerHTML without morph. The
// ext lives as /static/idiomorph.min.js and every full-page layout
// carries hx-ext="morph" so children inherit it. This test guards the
// invariant without touching layout math — outerHTML tear-down is the
// flicker.
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
				`hx-swap="morph:innerHTML"`,
				`id="system-cards"`,
				`id="downloads-summary"`,
				`hx-get="/partials/downloads-summary"`,
			},
			not: []string{
				`hx-swap="outerHTML"`,
			},
		},
		{
			path: "/verify",
			must: []string{
				`hx-ext="morph"`,
				`/static/idiomorph.min.js`,
				`id="verify-panel"`,
				`hx-trigger="every 2s"`,
				`hx-swap="morph:innerHTML"`,
				`hx-post="/verify"`,
				`hx-post="/dats/refresh"`,
			},
			not: []string{`hx-swap="outerHTML"`},
		},
		{
			path: "/metadata",
			must: []string{
				`hx-ext="morph"`,
				`/static/idiomorph.min.js`,
				`id="metadata-panel"`,
				`hx-swap="morph:innerHTML"`,
			},
			not: []string{`hx-swap="outerHTML"`},
		},
		{
			path: "/downloads",
			must: []string{
				`hx-ext="morph"`,
				`/static/idiomorph.min.js`,
				`id="downloads-panel"`,
				`hx-trigger="every 2s"`,
				`hx-swap="morph:innerHTML"`,
			},
			not: []string{`hx-swap="outerHTML"`},
		},
		{
			path: "/library",
			must: []string{
				`hx-ext="morph"`,
				`/static/idiomorph.min.js`,
			},
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
				t.Errorf("GET %s: body must not contain %q (morph fix regressed)", c.path, n)
			}
		}
	}
}

func TestPartialsUseMorphSwap(t *testing.T) {
	srv := newTestServer(t)
	h := srv.Handler()
	// Partials themselves must already carry morph:innerHTML so a
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
		if !strings.Contains(body, `hx-swap="morph:innerHTML"`) {
			t.Errorf("GET %s: missing morph:innerHTML", p)
		}
		if strings.Contains(body, `hx-swap="outerHTML"`) {
			t.Errorf("GET %s: must not contain outerHTML", p)
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
		if !strings.Contains(body, `hx-swap="morph:innerHTML"`) {
			t.Error("GET /partials/downloads-summary (configured): missing morph:innerHTML")
		}
		if strings.Contains(body, `hx-swap="outerHTML"`) {
			t.Error("GET /partials/downloads-summary (configured): must not contain outerHTML")
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
		if !strings.Contains(rec.Body.String(), `hx-swap="morph:innerHTML"`) {
			t.Errorf("GET %s: missing morph:innerHTML", p)
		}
	}
	h2 := newMetaServer(t)
	rec := httptest.NewRecorder()
	h2.srv.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/partials/metadata", nil))
	if rec.Code != 200 {
		t.Fatalf("GET /partials/metadata: %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), `hx-swap="morph:innerHTML"`) {
		t.Error("GET /partials/metadata: missing morph:innerHTML")
	}
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
