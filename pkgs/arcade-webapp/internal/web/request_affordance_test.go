package web

import (
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
)

// TestMutatingEndpointsAcceptNativeHtmxHeader pins the CSRF contract the
// browsers actually exercise: htmx natively sends `HX-Request: true` (it
// has never sent the custom X-HX-Request — the P2-era belief that broke
// every browser button until 2026-08-28). A POST carrying ONLY the native
// header must pass the hxRequestOK guard (202/409 — anything but 403),
// a POST carrying neither header must stay 403, and the custom header
// remains accepted for scripts/tests.
func TestMutatingEndpointsAcceptNativeHtmxHeader(t *testing.T) {
	vsrv, _ := newVerifyServer(t)
	h := vsrv.Handler()
	ep := "/systems/nes/dat-refresh"

	post := func(headers map[string]string) int {
		t.Helper()
		req := httptest.NewRequest(http.MethodPost, ep, nil)
		for k, v := range headers {
			req.Header.Set(k, v)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec.Code
	}

	if code := post(map[string]string{"HX-Request": "true"}); code == http.StatusForbidden {
		t.Errorf("POST %s with native HX-Request only = 403 — the browser header is rejected again", ep)
	}
	if code := post(map[string]string{"X-HX-Request": "true"}); code == http.StatusForbidden {
		t.Errorf("POST %s with custom X-HX-Request only = 403 — script compatibility regressed", ep)
	}
	if code := post(nil); code != http.StatusForbidden {
		t.Errorf("POST %s with neither header = %d, want 403 (CSRF posture lost)", ep, code)
	}
}

// TestSpinnerCSSScopedToRequester pins the in-flight affordance scoping:
// panel POLLS set htmx-request on the polled panel, so unscoped
// descendant rules flashed a spinner on (and dimmed) EVERY button in the
// panel every 2s/3s/10s tick. The served CSS must scope dim+spinner to
// the requesting button/form and must not contain the bare panel-level
// descendant selectors.
func TestSpinnerCSSScopedToRequester(t *testing.T) {
	srv := newTestServer(t)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/static/app.css", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /static/app.css: status %d", rec.Code)
	}
	css := rec.Body.String()

	must := []string{
		`button.htmx-request .htmx-indicator`, // pressed button lights its own spinner
		`form.htmx-request button`,            // submitting form dims its buttons
		`form.htmx-request .htmx-indicator`,   // form-scoped spinner
		`.htmx-request.htmx-indicator`,        // self-indicator form
		`button.htmx-request,`,
	}
	for _, m := range must {
		if !strings.Contains(css, m) {
			t.Errorf("app.css missing scoped selector %q", m)
		}
	}
	// Bare panel-level descendant selectors are the regression itself:
	// a poll on the panel would light/dim every descendant button.
	banned := []*regexp.Regexp{
		regexp.MustCompile(`(?m)^\.htmx-request \.htmx-indicator`),
		regexp.MustCompile(`(?m)^\.htmx-request button`),
	}
	for _, re := range banned {
		if re.MatchString(css) {
			t.Errorf("app.css contains unscoped selector %q — panel polls will flash every button", re)
		}
	}
}
