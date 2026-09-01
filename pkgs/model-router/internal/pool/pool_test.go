package pool

import (
	"testing"
	"time"

	"modelrouter/internal/health"
	"modelrouter/internal/ledger"
)

func newFixture() (*Pool, *health.Machine, *ledger.Ledger) {
	m := health.NewMachine()
	m.Tick(time.Now())
	led := ledger.New()
	return New(m, led, 0.5), m, led
}

func ep(provider, model string, rpm float64) Endpoint {
	return Endpoint{
		Scope:   health.Scope{Provider: provider, Model: model, Key: "k"},
		Weights: map[string]float64{"rpm": rpm},
	}
}

func TestSelectGatesBlockedScopes(t *testing.T) {
	p, m, _ := newFixture()
	blocked := health.Scope{Provider: "groq", Model: "qwen3.8-27b", Key: "k"}
	p.SetMembers("qwen3.8", []Endpoint{ep("groq", "qwen3.8-27b", 30), ep("nim", "qwen3.8-27b", 40)})
	m.Set(blocked, health.RateLimit, time.Hour, health.Heuristic, "429 storm")

	for i := 0; i < 10; i++ {
		got, ok, reason := p.Select("qwen3.8", nil)
		if !ok {
			t.Fatalf("select %d failed: %v", i, reason)
		}
		if got.Scope.Provider == "groq" {
			t.Fatalf("select %d chose health-blocked groq (vetoes: %v)", i, reason.Vetoes)
		}
		p.Release(got.Scope)
	}
}

func TestSelectFailsOpenWhenAllBlocked(t *testing.T) {
	p, m, _ := newFixture()
	sc1 := health.Scope{Provider: "a", Model: "m", Key: "k"}
	m.Set(sc1, health.RateLimit, time.Hour, health.Heuristic, "storm a")
	p.SetMembers("m", []Endpoint{ep("a", "m", 10)})
	if _, ok, reason := p.Select("m", nil); !ok {
		t.Fatalf("fail-open must serve from blocked set when every member is down: %v", reason)
	}
}

func TestDRRComposedShareSkewsTowardCapacity(t *testing.T) {
	p, _, _ := newFixture()
	// under the full composition, the bigger endpoint still wins a clear
	// majority — the pure-scheduler 4:1 is drr_test.go's concern; here we
	// assert the composition preserves capacity direction (>= 1.6:1)
	big := ep("big", "m", 512)
	small := ep("small", "m", 128)
	p.SetMembers("m", []Endpoint{big, small})
	counts := map[string]int{}
	for i := 0; i < 320; i++ {
		got, ok, _ := p.Select("m", nil)
		if !ok {
			t.Fatal("select failed")
		}
		counts[got.Scope.Provider]++
		p.Release(got.Scope)
	}
	ratio := float64(counts["big"]) / float64(counts["small"])
	if ratio < 1.6 {
		t.Fatalf("composed share ratio = %.1f, want >= 1.6 toward capacity (got %v)", ratio, counts)
	}
}

func TestP2CPrefersFewerInFlight(t *testing.T) {
	p, _, _ := newFixture()
	busy := ep("busy", "m", 100)
	idle := ep("idle", "m", 100)
	p.SetMembers("m", []Endpoint{busy, idle})
	// busy carries 5 in-flight (reported externally)
	inFlight := func(sc health.Scope) int {
		if sc.Provider == "busy" {
			return 5
		}
		return 0
	}
	busyWins, idleWins := 0, 0
	for i := 0; i < 100; i++ {
		got, ok, _ := p.Select("m", inFlight)
		if !ok {
			t.Fatal("select failed")
		}
		if got.Scope.Provider == "busy" {
			busyWins++
		} else {
			idleWins++
		}
		p.Release(got.Scope)
	}
	// with equal weights, DRR splits evenly; P2C should skew toward idle
	if idleWins < 55 {
		t.Fatalf("P2C failed to prefer idle endpoint: busy=%d idle=%d", busyWins, idleWins)
	}
}

func TestScoreDemoteNotDrop(t *testing.T) {
	p, _, _ := newFixture()
	flaky := ep("flaky", "m", 100)
	steady := ep("steady", "m", 100)
	p.SetMembers("m", []Endpoint{flaky, steady})
	// flaky fails 20 times, steady succeeds 20 times
	for i := 0; i < 20; i++ {
		p.ReportOutcome(flaky.Scope, false, 0)
		p.ReportOutcome(steady.Scope, true, 100*time.Millisecond)
	}
	steadyWins := 0
	for i := 0; i < 60; i++ {
		got, ok, _ := p.Select("m", nil)
		if !ok {
			t.Fatal("select failed")
		}
		if got.Scope.Provider == "steady" {
			steadyWins++
		}
		p.Release(got.Scope)
	}
	if steadyWins < 45 {
		t.Fatalf("failing endpoint not demoted: steady=%d/60", steadyWins)
	}
	// never dropped: flaky still in the pool and selectable in the chain
	if members := p.Members("m"); len(members) != 2 {
		t.Fatalf("members = %d, want 2 — demote, never drop", len(members))
	}
	if chain := p.Chain("m"); len(chain) != 2 {
		t.Fatalf("chain = %d, want 2", len(chain))
	}
}

func TestChainRanksUnblockedFirst(t *testing.T) {
	p, m, _ := newFixture()
	down := ep("down", "m", 100)
	up := ep("up", "m", 100)
	p.SetMembers("m", []Endpoint{down, up})
	m.Set(down.Scope, health.Circuit, time.Hour, health.Heuristic, "breaker open")
	chain := p.Chain("m")
	if chain[0].Scope.Provider != "up" {
		t.Fatalf("chain[0] = %s, want unblocked 'up' first", chain[0].Scope.Provider)
	}
}

func TestColdStartGetsTried(t *testing.T) {
	p, _, _ := newFixture()
	// unseen endpoint with uniform prior must win sometimes against a
	// mediocre incumbent (Beta(3,3) mean 0.5) — Thompson exploration
	incumbent := ep("incumbent", "m", 100)
	fresh := ep("fresh", "m", 100)
	p.SetMembers("m", []Endpoint{incumbent, fresh})
	for i := 0; i < 6; i++ {
		p.ReportOutcome(incumbent.Scope, i%2 == 0, 0) // 3 success 3 fail
	}
	freshWins := 0
	for i := 0; i < 200; i++ {
		got, ok, _ := p.Select("m", nil)
		if !ok {
			t.Fatal("select failed")
		}
		if got.Scope.Provider == "fresh" {
			freshWins++
		}
		p.Release(got.Scope)
	}
	if freshWins < 20 {
		t.Fatalf("cold-start endpoint never explored: fresh=%d/200", freshWins)
	}
}
