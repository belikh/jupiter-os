package health

import (
	"strings"
	"sync"
	"testing"
	"time"
)

var t0 = time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)

func newPrimed() *Machine {
	m := NewMachine()
	m.Tick(t0)
	return m
}

func TestSetAndBlocksUntilExpiry(t *testing.T) {
	m := newPrimed()
	sc := Scope{Provider: "openrouter", Model: "glm-5.2:free", Key: "k1"}
	m.Set(sc, RateLimit, 90*time.Second, Heuristic, "transient 429 from openrouter")

	blocked, why, until := m.Blocks(sc)
	if !blocked {
		t.Fatal("expected scope blocked after Set")
	}
	if !strings.Contains(why, "transient 429") {
		t.Fatalf("why = %q, want reason carried through", why)
	}
	want := t0.Add(90 * time.Second)
	if !until.Equal(want) {
		t.Fatalf("until = %v, want %v", until, want)
	}

	// after expiry it no longer blocks
	m.Tick(t0.Add(91 * time.Second))
	blocked, _, _ = m.Blocks(sc)
	if blocked {
		t.Fatal("expected scope unblocked after expiry")
	}
}

func TestBlocksReturnsEarliestExpiryReason(t *testing.T) {
	m := newPrimed()
	sc := Scope{Provider: "groq", Model: "qwen3.8-27b", Key: "k"}
	m.Set(sc, Quota, 24*time.Hour, Authoritative, "daily quota exhausted until reset")
	m.Set(sc, RateLimit, 60*time.Second, Heuristic, "rpm burst")
	blocked, why, until := m.Blocks(sc)
	if !blocked {
		t.Fatal("expected blocked")
	}
	if !strings.Contains(why, "rpm burst") {
		t.Fatalf("why = %q, want earliest-expiring state's reason", why)
	}
	if !until.Equal(t0.Add(60 * time.Second)) {
		t.Fatalf("until = %v, want earliest expiry", until)
	}
}

func TestProvenanceGatesProbeEligibility(t *testing.T) {
	m := newPrimed()
	h := Scope{Provider: "p", Model: "m", Key: "heuristic"}
	a := Scope{Provider: "p", Model: "m", Key: "authoritative"}
	m.Set(h, RateLimit, time.Minute, Heuristic, "guess")
	m.Set(a, Quota, time.Hour, Authoritative, "provider stated")
	if !m.ProbeEligible(h, RateLimit) {
		t.Fatal("heuristic cooldown should be probe-eligible")
	}
	if m.ProbeEligible(a, Quota) {
		t.Fatal("authoritative cooldown must never be probe-eligible")
	}
}

func TestQuotaEscalationLadder(t *testing.T) {
	m := newPrimed()
	sc := Scope{Provider: "openrouter", Model: "m:free", Key: "k"}
	steps := []time.Duration{10 * time.Minute, 2 * time.Minute, 10 * time.Minute, time.Hour, 24 * time.Hour}
	// first hit keeps the caller TTL
	m.Set(sc, Quota, 10*time.Minute, Heuristic, "daily quota gone")
	if got := m.states[sc][Quota].expiresAt.Sub(t0); got != 10*time.Minute {
		t.Fatalf("first hit TTL = %v, want caller TTL", got)
	}
	for i, want := range steps[1:] {
		m.Set(sc, Quota, 10*time.Minute, Heuristic, "daily quota gone")
		if got := m.states[sc][Quota].expiresAt.Sub(t0); got != want {
			t.Fatalf("repeat %d TTL = %v, want %v", i+1, got, want)
		}
	}
	// fifth repeat and beyond stay on the top rung
	m.Set(sc, Quota, 10*time.Minute, Heuristic, "daily quota gone")
	if got := m.states[sc][Quota].expiresAt.Sub(t0); got != 24*time.Hour {
		t.Fatalf("capped TTL = %v, want 24h", got)
	}

	// Success resets the ladder
	m.Success(sc)
	m.Set(sc, Quota, 10*time.Minute, Heuristic, "daily quota gone")
	if got := m.states[sc][Quota].expiresAt.Sub(t0); got != 10*time.Minute {
		t.Fatalf("post-success TTL = %v, want base again", got)
	}
}

func TestAuthoritativeOverridesHeuristicLadder(t *testing.T) {
	m := newPrimed()
	sc := Scope{Provider: "zai", Model: "glm-4.7-flash", Key: "k"}
	m.Set(sc, Quota, time.Hour, Heuristic, "quota guess")
	m.Set(sc, Quota, 5*time.Hour, Authoritative, "1308 usage limit until next flush")
	if got := m.states[sc][Quota].expiresAt.Sub(t0); got != 5*time.Hour {
		t.Fatalf("authoritative TTL = %v, want 5h", got)
	}
	if m.ProbeEligible(sc, Quota) {
		t.Fatal("authoritative quota must not be probe-eligible")
	}
}

func TestBillingMarkerTakes24h(t *testing.T) {
	m := newPrimed()
	sc := Scope{Provider: "zai", Model: "glm-4.7-flash", Key: "k"}
	m.Set(sc, RateLimit, time.Second, Heuristic, "1113 billing rejection masquerading as 429")
	if got := m.states[sc][RateLimit].expiresAt.Sub(t0); got != 24*time.Hour {
		t.Fatalf("billing TTL = %v, want 24h", got)
	}
}

func TestClearAndAllBlocked(t *testing.T) {
	m := newPrimed()
	sc := Scope{Provider: "p", Model: "m", Key: "k"}
	other := Scope{Provider: "p", Model: "m", Key: "k2"}
	m.Set(sc, Circuit, time.Hour, Heuristic, "breaker open")
	m.Set(other, Circuit, time.Hour, Heuristic, "breaker open")
	scopes := []Scope{sc, other}
	if !m.AllBlocked(scopes, "m") {
		t.Fatal("expected all blocked")
	}
	m.Clear(sc, Circuit)
	if m.AllBlocked(scopes, "m") {
		t.Fatal("expected fail-open after clearing one")
	}
	// model filter: a different model's scopes don't count
	m2 := newPrimed()
	s := Scope{Provider: "p", Model: "a", Key: "k"}
	m2.Set(s, RateLimit, time.Hour, Heuristic, "x")
	if m2.AllBlocked([]Scope{s}, "b") {
		t.Fatal("model filter broken: counted a different model")
	}
}

func TestEventsRingAndHook(t *testing.T) {
	m := newPrimed()
	var hooked []Event
	m.SetEventHook(func(ev Event) { hooked = append(hooked, ev) })
	sc := Scope{Provider: "p", Model: "m", Key: "k"}
	m.Set(sc, RateLimit, time.Minute, Heuristic, "reason one")
	m.Clear(sc, RateLimit)
	m.Success(sc)
	evs := m.Events(10)
	if len(evs) != 3 {
		t.Fatalf("events = %d, want 3", len(evs))
	}
	if evs[0].Kind != "success" || evs[1].Kind != "clear" || evs[2].Kind != "set" {
		t.Fatalf("events not newest-first: %v %v %v", evs[0].Kind, evs[1].Kind, evs[2].Kind)
	}
	if len(hooked) != 3 {
		t.Fatalf("hook events = %d, want 3", len(hooked))
	}
}

func TestEventRingOverflow(t *testing.T) {
	m := NewMachine()
	m.Tick(t0)
	sc := Scope{Provider: "p", Model: "m"}
	for i := 0; i < eventRingSize+100; i++ {
		m.Set(sc, RateLimit, time.Minute, Heuristic, "r")
	}
	if len(m.events) != eventRingSize {
		t.Fatalf("ring len = %d, want %d", len(m.events), eventRingSize)
	}
}

func TestConcurrentUse(t *testing.T) {
	m := newPrimed()
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			sc := Scope{Provider: "p", Model: "m", Key: string(rune('a' + i%8))}
			m.Set(sc, RateLimit, time.Minute, Heuristic, "concurrent")
			m.Blocks(sc)
			m.Events(5)
			m.Success(sc)
		}(i)
	}
	wg.Wait()
}
