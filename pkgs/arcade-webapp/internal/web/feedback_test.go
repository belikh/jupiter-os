package web

import (
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
)

func TestFeedbackIndicatorsPins(t *testing.T) {
	{
		srv := newTestServer(t)
		body := get(t, srv.Handler(), "/").Body.String()
		for _, m := range []string{
			`hx-indicator="closest button"`,
			`hx-disabled-elt="this"`,
			`class="htmx-indicator spinner"`,
			`id="toast"`,
			`role="status" aria-live="polite"`,
		} {
			if !strings.Contains(body, m) {
				t.Errorf("GET / missing feedback marker %q", m)
			}
		}
		if !strings.Contains(body, `hx-post="/rescan"`) {
			t.Error("GET / missing rescan POST")
		}
	}
	{
		srv, _ := newVerifyServer(t)
		body := get(t, srv.Handler(), "/verify").Body.String()
		for _, m := range []string{
			`hx-post="/verify"`,
			`hx-post="/dats/refresh"`,
			`hx-post="/systems/nes/verify"`,
			`hx-post="/systems/nes/dat-refresh"`,
			`hx-indicator="closest button"`,
			`hx-indicator="this"`,
			`htmx-indicator spinner`,
		} {
			if !strings.Contains(body, m) {
				t.Errorf("GET /verify missing %q", m)
			}
		}
	}
	{
		h := newMetaServer(t)
		body := get(t, h.srv.Handler(), "/metadata").Body.String()
		for _, m := range []string{
			`hx-post="/metadata/scrape"`,
			`hx-post="/systems/nes/scrape"`,
			`hx-indicator="closest button"`,
			`hx-indicator="this"`,
			`htmx-indicator spinner`,
		} {
			if !strings.Contains(body, m) {
				t.Errorf("GET /metadata missing %q", m)
			}
		}
	}
	{
		h := newGenServer(t)
		body := get(t, h.srv.Handler(), "/metadata").Body.String()
		if !strings.Contains(body, `hx-post="/generate"`) {
			t.Errorf("GET /metadata (gen) missing generate button")
		}
	}
	{
		root := t.TempDir()
		srv, _ := newDownloadsServer(t, root)
		body := get(t, srv.Handler(), "/downloads").Body.String()
		for _, m := range []string{
			`hx-post="/downloads/`,
			`hx-indicator="this"`,
			`htmx-indicator spinner`,
		} {
			if !strings.Contains(body, m) {
				t.Errorf("GET /downloads missing %q", m)
			}
		}
	}
	{
		h := newMetaServer(t)
		gid := firstGameID(t, h.srv, "nes")
		rec := httptest.NewRecorder()
		h.srv.Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/systems/nes/games/"+strconv.FormatInt(gid, 10), nil))
		if rec.Code != 200 {
			t.Fatalf("GET game detail = %d", rec.Code)
		}
		body := rec.Body.String()
		for _, m := range []string{
			`hx-post="/systems/nes/games/`,
			`hx-indicator="this"`,
			`htmx-indicator spinner`,
		} {
			if !strings.Contains(body, m) {
				t.Errorf("game detail missing %q", m)
			}
		}
	}
}

func TestRecentRunsCappedAndDeduped(t *testing.T) {
	srv := newTestServer(t)
	for i := 0; i < 20; i++ {
		id, _ := srv.st.StartRun("scan")
		_ = srv.st.FinishRun(id, "ok", `{"Systems":1,"Games":1,"Bytes":1}`)
	}
	body := get(t, srv.Handler(), "/").Body.String()
	count := strings.Count(body, `id="run-`)
	if count > 10 || count < 5 {
		t.Errorf("recent runs count = %d, want 5-10 capped", count)
	}
	if count == 0 {
		t.Error("no run rows rendered")
	}
	seen := map[string]int{}
	for _, line := range strings.Split(body, "\n") {
		if strings.Contains(line, `id="run-`) {
			s := line
			if idx := strings.Index(s, `id="run-`); idx >= 0 {
				start := idx + len(`id="`)
				end := strings.Index(s[start:], `"`)
				if end >= 0 {
					id := s[start : start+end]
					seen[id]++
				}
			}
		}
	}
	for id, n := range seen {
		if n > 1 {
			t.Errorf("run id %s appears %d times, want deduped", id, n)
		}
	}
	if !strings.Contains(body, `hx-swap="morph:innerHTML"`) {
		t.Error("dashboard polling must use morph:innerHTML")
	}
}

func TestMetadataRowShowsOutcomeCountsAndDescription(t *testing.T) {
	h := newMetaServer(t)
	if rec := postHX(t, h.srv.Handler(), "/systems/nes/scrape"); rec.Code != http.StatusAccepted {
		t.Fatalf("POST /systems/nes/scrape = %d", rec.Code)
	}
	waitScrapeSettled(t, h, 1)
	body := get(t, h.srv.Handler(), "/metadata").Body.String()
	for _, m := range []string{
		`data-system="nes"`,
		`scraped</span>`,
		`5 games`,
		`data-desc-pct="100"`,
		`data-cover-pct="100"`,
	} {
		if !strings.Contains(body, m) {
			t.Errorf("metadata after scrape missing %q", m)
		}
	}
	id, _ := h.srv.st.StartRun("scrape")
	_ = h.srv.st.FinishRun(id, "error", `{"Systems":[{"Sys":"gb","Outcome":"failed","Err":"all 2 pass(es) failed: boom","Desc":0,"Cover":0}]}`)
	body2 := get(t, h.srv.Handler(), "/metadata").Body.String()
	if !strings.Contains(body2, `data-system="gb"`) {
		t.Fatalf("gb row missing after failed run injection")
	}
	if !strings.Contains(body2, `failed</span>`) {
		t.Error("failed outcome pill not rendered")
	}
	if !strings.Contains(body2, `boom`) {
		t.Error("SystemOutcome Err not surfaced in metadata")
	}
}
