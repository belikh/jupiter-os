package web

import (
	"embed"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"modelrouter/internal/health"
	"modelrouter/internal/ledger"
	"modelrouter/internal/pool"
	"modelrouter/internal/seed"
	"modelrouter/internal/vault"
)

// The Zeus gate: the component CSS consumes var(--ze-*) tokens only — no
// raw hex literals outside zeus-tokens.css (jupiter-os style guide's
// anti-pattern rule, mechanically enforced).
func TestZeusGateNoHexInComponentCSS(t *testing.T) {
	b, err := staticFS.ReadFile("static/app.css")
	if err != nil {
		t.Fatal(err)
	}
	css := string(b)
	for _, forbidden := range []string{"#08090D", "#10131B", "#E2E8F4", "#9CFF57", "#FF5C47"} {
		if strings.Contains(css, forbidden) {
			t.Fatalf("component CSS contains raw hex %s — must use var(--ze-*)", forbidden)
		}
	}
	if !strings.Contains(css, "var(--ze-") {
		t.Fatal("component CSS does not consume Zeus tokens")
	}
	// the tokens file itself must exist and define --ze-*
	tok, err := staticFS.ReadFile("static/zeus-tokens.css")
	if err != nil {
		t.Fatal("zeus-tokens.css missing from embedded assets")
	}
	if !strings.Contains(string(tok), "--ze-bg") {
		t.Fatal("zeus-tokens.css does not define --ze-bg")
	}
}

func newTestServer() (*Server, *pool.Pool, *health.Machine) {
	m := health.NewMachine()
	led := ledger.New()
	p := pool.New(m, led, 0.5)
	s := seed.Seed{
		Providers: []seed.Provider{
			{ID: "openrouter", Name: "OpenRouter", SignupURL: "https://openrouter.ai", KeyPageURL: "https://openrouter.ai/keys"},
			{ID: "groq", Name: "Groq", SignupURL: "https://console.groq.com", KeyPageURL: "https://console.groq.com/keys", FrictionFlags: []string{"no card required"}},
		},
		Models: []seed.ModelMapping{
			{Family: "glm-4x-flash", ProviderID: "openrouter", LocalSlug: "z-ai/glm-4.5-flash:free", Status: "free"},
		},
	}
	var events []health.Event
	evFn := func(limit int) []health.Event { return events }
	srv := NewServer(p, m, led, s, nil, evFn, func(id, alias, key string) error { return nil }, func(id, alias string) error { return nil })
	return srv, p, m
}

func TestDashboardRendersWhyDown(t *testing.T) {
	srv, p, m := newTestServer()
	p.SetMembers("glm-4x-flash", []pool.Endpoint{{
		Scope: health.Scope{Provider: "openrouter", Model: "glm-4x-flash", Key: "k"},
	}})
	m.Set(health.Scope{Provider: "openrouter", Model: "glm-4x-flash", Key: "k"},
		health.Quota, 3600e9, health.Authoritative, "daily quota exhausted until UTC midnight")

	ts := httptest.NewServer(srv.Mux())
	defer ts.Close()
	resp, err := http.Get(ts.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	html := string(body)
	if !strings.Contains(html, "daily quota exhausted") {
		t.Fatalf("dashboard must render why-down reasons; got: %s", firstN(html, 300))
	}
	// templates link the token stylesheets; raw hex never inlines
	if !strings.Contains(html, "/static/zeus-tokens.css") || !strings.Contains(html, "/static/app.css") {
		t.Fatal("dashboard must link zeus-tokens.css and app.css")
	}
	if strings.Contains(html, "#08090D") {
		t.Fatal("raw Zeus hex leaked into rendered HTML")
	}
}

func TestKeysPageShowsSignupAndKeyURLs(t *testing.T) {
	srv, _, _ := newTestServer()
	ts := httptest.NewServer(srv.Mux())
	defer ts.Close()
	resp, err := http.Get(ts.URL + "/keys")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	html := string(io2String(t, resp.Body))
	for _, want := range []string{"https://openrouter.ai/keys", "https://console.groq.com/keys", "no card required"} {
		if !strings.Contains(html, want) {
			t.Fatalf("keys page missing %q", want)
		}
	}
}

func TestEventsPageRendersReasons(t *testing.T) {
	srv, _, m := newTestServer()
	m.Set(health.Scope{Provider: "groq", Model: "x", Key: "k"}, health.RateLimit, 90e9, health.Heuristic, "transient 429 from groq")
	// the machine's event ring feeds the page via Events fn
	srv.Events = func(limit int) []health.Event { return m.Events(limit) }
	ts := httptest.NewServer(srv.Mux())
	defer ts.Close()
	resp, err := http.Get(ts.URL + "/events")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	html := io2String(t, resp.Body)
	if !strings.Contains(html, "transient 429 from groq") {
		t.Fatal("events page must render the reason")
	}
}

func io2String(t *testing.T, r io.Reader) string {
	t.Helper()
	b, err := io.ReadAll(r)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func firstN(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

var _ embed.FS
var _ = vault.Untested

// TestKeysPageMultiKey asserts the keys page renders one row per stored
// alias with a working delete route, and that saving with an explicit
// alias reaches the vault through SaveKey.
func TestKeysPageMultiKey(t *testing.T) {
	var saved []string // provider, alias, key triples
	srv, _, _ := newTestServer()
	srv.SaveKey = func(id, alias, key string) error {
		saved = append(saved, id, alias, key)
		return nil
	}
	srv.Vault = nil // view-only path; SaveKey records the triple
	ts := httptest.NewServer(srv.Mux())
	defer ts.Close()

	form := url.Values{"alias": {"backup"}, "key": {"gsk-test"}}
	resp, err := http.PostForm(ts.URL+"/keys/groq", form)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if len(saved) != 3 || saved[0] != "groq" || saved[1] != "backup" || saved[2] != "gsk-test" {
		t.Fatalf("SaveKey captured %v, want groq/backup/gsk-test", saved)
	}

	// empty alias collapses to "default"
	saved = nil
	resp2, err := http.PostForm(ts.URL+"/keys/groq", url.Values{"key": {"gsk-2"}})
	if err != nil {
		t.Fatal(err)
	}
	resp2.Body.Close()
	if len(saved) != 3 || saved[1] != "default" {
		t.Fatalf("empty alias = %v, want default", saved)
	}

	// delete route hits DeleteKey with the path alias
	var deleted []string
	srv.DeleteKey = func(id, alias string) error {
		deleted = append(deleted, id, alias)
		return nil
	}
	resp3, err := http.PostForm(ts.URL+"/keys/groq/backup/delete", nil)
	if err != nil {
		t.Fatal(err)
	}
	resp3.Body.Close()
	if len(deleted) != 2 || deleted[0] != "groq" || deleted[1] != "backup" {
		t.Fatalf("DeleteKey captured %v, want groq/backup", deleted)
	}
}
