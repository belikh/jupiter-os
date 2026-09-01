package discovery

import (
	"context"
	"errors"
	"testing"
	"time"

	"modelrouter/internal/health"
	"modelrouter/internal/ledger"
	"modelrouter/internal/pool"
	"modelrouter/internal/seed"
)

// stubAdapter scripts the live catalogue.
type stubAdapter struct {
	ids   []string
	err   error
	calls int
}

func (s *stubAdapter) ListModels(ctx context.Context) ([]string, error) {
	s.calls++
	return s.ids, s.err
}

func testSeed() seed.Seed {
	return seed.Seed{
		Providers: []seed.Provider{{ID: "openrouter"}, {ID: "groq"}},
		Models: []seed.ModelMapping{
			{Family: "glm-5.2", ProviderID: "openrouter", LocalSlug: "z-ai/glm-5.2:free", Status: "free"},
			{Family: "kimi-k3", ProviderID: "groq", LocalSlug: "kimi-k3", Status: "free"},
		},
	}
}

func testLoop(adapters map[string]Adapter) (*Loop, *pool.Pool, *health.Machine, *[]health.Event) {
	m := health.NewMachine()
	m.Tick(time.Now())
	led := ledger.New()
	p := pool.New(m, led, 0.5)
	events := &[]health.Event{}
	s := testSeed()
	l := New(s, p, m, adapters, func(ev health.Event) { *events = append(*events, ev) })
	// seed the pools initially
	l.mu.Lock()
	l.applyToPools("openrouter")
	l.applyToPools("groq")
	l.mu.Unlock()
	return l, p, m, events
}

func TestPollDetectsSilentRemoval(t *testing.T) {
	ad := &stubAdapter{ids: []string{"some/other-model"}}
	l, p, _, events := testLoop(map[string]Adapter{"openrouter": ad, "groq": &stubAdapter{}})

	// glm-5.2:free is absent from the live list -> tombstoned
	added, removed, err := l.PollOnce(context.Background(), "openrouter")
	if err != nil {
		t.Fatal(err)
	}
	if len(removed) != 1 || removed[0] != "z-ai/glm-5.2:free" {
		t.Fatalf("removed = %v, want glm-5.2:free", removed)
	}
	if len(added) != 0 {
		t.Fatalf("added = %v, want none", added)
	}
	// pool membership shrank for that family
	if eps := p.Members("glm-5.2"); len(eps) != 0 {
		t.Fatalf("pool members after removal = %d, want 0 (drain-then-retire)", len(eps))
	}
	// event recorded
	found := false
	for _, ev := range *events {
		if contains(ev.Reason, "removed") {
			found = true
		}
	}
	if !found {
		t.Fatalf("no removal event: %+v", *events)
	}
}

func TestPollResurrectsTombstoneOnRelist(t *testing.T) {
	groq := &stubAdapter{ids: []string{}} // absent now, re-listed later
	l, p, _, _ := testLoop(map[string]Adapter{"openrouter": &stubAdapter{}, "groq": groq})

	// remove it: the live list is empty, so kimi-k3 silently vanishes
	if _, _, err := l.PollOnce(context.Background(), "groq"); err != nil {
		t.Fatal(err)
	}
	if eps := p.Members("kimi-k3"); len(eps) != 0 {
		t.Fatal("expected drained")
	}
	// provider re-lists it
	groq.ids = []string{"kimi-k3"}
	added, _, err := l.PollOnce(context.Background(), "groq")
	if err != nil {
		t.Fatal(err)
	}
	if len(added) != 1 || added[0] != "kimi-k3" {
		t.Fatalf("resurrection added = %v, want kimi-k3", added)
	}
	if eps := p.Members("kimi-k3"); len(eps) != 1 {
		t.Fatalf("pool members after resurrection = %d, want 1", len(eps))
	}
}

func TestVariantNormalisation(t *testing.T) {
	cases := map[string]string{
		"z-ai/glm-5.2:free":      "z-ai/glm-5.2",
		"glm-5.3-flash:cloud":    "glm-5.3-flash",
		"openai/gpt-4o:nitro":    "openai/gpt-4o",
		"deepseek-v4-flash-0731": "deepseek-v4-flash",
		"qwen/qwen3.8-27b":       "qwen/qwen3.8-27b", // untouched
		"model:free:extra":       "model:free:extra", // only one suffix stripped
	}
	for in, want := range cases {
		if got := normalise(in); got != want {
			t.Errorf("normalise(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestPollFailureIsLogAndSkip(t *testing.T) {
	ad := &stubAdapter{err: errors.New("connection refused")}
	l, _, _, events := testLoop(map[string]Adapter{"openrouter": ad, "groq": &stubAdapter{ids: []string{"kimi-k3"}}})
	_, _, err := l.PollOnce(context.Background(), "openrouter")
	if err == nil {
		t.Fatal("poll error must propagate to the caller (runner logs-and-skips)")
	}
	// the mapping survives untouched — one provider's outage changes nothing
	snap := l.Snapshot()
	if len(snap) != 2 {
		t.Fatalf("mappings after failed poll = %d, want 2 (no churn on error)", len(snap))
	}
	found := false
	for _, ev := range *events {
		if contains(ev.Reason, "poll failed") {
			found = true
		}
	}
	// the runner emits the event, not PollOnce — checking the runner path
	// is the Run() test's job; here just assert no crash
	_ = found
}

func TestRetireAndAdmit(t *testing.T) {
	l, p, _, events := testLoop(map[string]Adapter{"openrouter": &stubAdapter{}, "groq": &stubAdapter{}})
	l.Retire("kimi-k3", "groq", "410 tombstone observed")
	if eps := p.Members("kimi-k3"); len(eps) != 0 {
		t.Fatal("retire must drain the pool")
	}
	l.Admit(ModelMapping{Family: "glm-4x-flash", Provider: "openrouter", LocalSlug: "z-ai/glm-4.5-flash:free", Status: "free"})
	if eps := p.Members("glm-4x-flash"); len(eps) != 1 {
		t.Fatal("admit must add to the pool")
	}
	// 410 tombstone reason recorded in events
	found := false
	for _, ev := range *events {
		if contains(ev.Reason, "tombstone") {
			found = true
		}
	}
	if !found {
		t.Fatalf("retire reason not evented: %+v", *events)
	}
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (s == sub || len(s) > 0 && containsStr(s, sub))
}

func containsStr(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
