// Package pool assembles per-model endpoint pools and selects the best
// candidate under the health machine's gates and the ledger's headroom —
// the staged composition the research corpus converged on: hard gates,
// then capacity-proportional DRR, then bounded power-of-two-choices over
// in-flight counts, with a Thompson-sampled scoring base that demotes
// (never reorders) on live failures.
package pool

import (
	"math/rand"
	"sort"
	"sync"
	"time"

	"modelrouter/internal/health"
	"modelrouter/internal/ledger"
)

// Endpoint is one pool member: a provider-model-key triple plus the
// capability metadata the scorer uses.
type Endpoint struct {
	Scope   health.Scope
	Weights map[string]float64 // cap-share weights for DRR (rpm/rpd-derived)
	Family  string             // canonical model family (identity key part)
	LocalID string             // provider-local slug
}

// Pool owns the per-model endpoint sets and all selection state.
type Pool struct {
	mu         sync.Mutex
	members    map[string][]Endpoint // model family -> endpoints
	drr        *DRR
	score      *Score
	machine    *health.Machine
	led        *ledger.Ledger
	inFlight   map[health.Scope]int
	probefloor float64
	rng        *rand.Rand
}

// New constructs a Pool over the shared health machine and ledger.
// probeFloor is the minimum ledger headroom ratio under which heuristic
// probing is refused (the probe economy: probes are quota).
func New(machine *health.Machine, led *ledger.Ledger, probeFloor float64) *Pool {
	return &Pool{
		members:    make(map[string][]Endpoint),
		drr:        NewDRR(),
		score:      NewScore(rand.NewSource(time.Now().UnixNano())),
		machine:    machine,
		led:        led,
		inFlight:   make(map[health.Scope]int),
		probefloor: probeFloor,
		rng:        rand.New(rand.NewSource(time.Now().UnixNano() + 1)),
	}
}

// SetMembers replaces the endpoint set for a model family (discovery calls
// this after catalogue changes; drain-then-retire is the caller's concern).
func (p *Pool) SetMembers(family string, endpoints []Endpoint) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.members[family] = endpoints
	p.drr.Configure(family, endpoints)
}

// Members returns a copy of the current endpoint set for a family.
func (p *Pool) Members(family string) []Endpoint {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]Endpoint, len(p.members[family]))
	copy(out, p.members[family])
	return out
}

// SelectionReason records why a candidate won (or the pool failed) — the
// dashboard's reason trail.
type SelectionReason struct {
	Family string
	Chosen *Endpoint
	Why    string
	Vetoes []string // candidates blocked, with their health reason
}

// Select picks the next endpoint for a model family through the staged
// composition. inFlightFn reports a scope's current in-flight requests
// (nil uses the pool's own counter).
func (p *Pool) Select(family string, inFlightFn func(health.Scope) int) (Endpoint, bool, SelectionReason) {
	p.mu.Lock()
	defer p.mu.Unlock()

	members := p.members[family]
	if len(members) == 0 {
		return Endpoint{}, false, SelectionReason{Family: family, Why: "no endpoints in pool"}
	}

	// Stage 1 — hard gates: health blocks + ledger headroom.
	var eligible []Endpoint
	var vetoes []string
	allBlocked := true
	for _, e := range members {
		if blocked, why, _ := p.machine.Blocks(e.Scope); blocked {
			vetoes = append(vetoes, e.Scope.Provider+"/"+e.Scope.Model+": "+why)
			continue
		}
		allBlocked = false
		if p.led.HeadroomRatio(e.Scope) <= 0 {
			vetoes = append(vetoes, e.Scope.Provider+"/"+e.Scope.Model+": quota exhausted (ledger)")
			continue
		}
		eligible = append(eligible, e)
	}

	// Fail-open: every member blocked or spent — bypass the filters and
	// let the walk try the least-bad, rather than erroring at the pool.
	if len(eligible) == 0 {
		if allBlocked {
			// everything health-blocked: serve from the full set anyway
			eligible = members
		} else {
			// everything quota-spent: same bypass, the walk will 429 and
			// the health machine will learn the authoritative reset
			eligible = members
		}
	}

	count := func(sc health.Scope) int {
		if inFlightFn != nil {
			return inFlightFn(sc)
		}
		return p.inFlight[sc]
	}

	// Stage 2 — capacity-proportional DRR picks the primary.
	primary, ok := p.drr.Next(family, eligible)
	if !ok {
		return Endpoint{}, false, SelectionReason{Family: family, Why: "DRR found no candidate", Vetoes: vetoes}
	}

	// Stage 3 — bounded P2C: sample a challenger weighted by cap share and
	// take the one with fewer in-flight — but only when the primary is
	// actually loaded. An idle primary is never displaced (the corpus's
	// bounded-P2C guard: challenging an idle candidate just re-randomises
	// DRR's carefully-weighted share and drags capacity back toward even).
	chosen := primary
	if len(eligible) > 1 && count(primary.Scope) > 0 {
		challenger := p.sampleProportional(family, eligible, primary.Scope)
		if challenger.Scope != primary.Scope && count(challenger.Scope) < count(primary.Scope) {
			chosen = challenger
		}
	}

	// Stage 4 — Thompson-Beta scoring base: demote-not-drop. A candidate
	// whose live score collapses loses to a healthy challenger but is
	// never removed from the pool.
	p.score.AdjustOrder(family, &chosen, eligible, count)

	p.inFlight[chosen.Scope]++
	why := "gates+DRR"
	if chosen.Scope != primary.Scope {
		why = "gates+DRR+P2C"
	}
	reason := SelectionReason{
		Family: family,
		Chosen: &chosen,
		Why:    why,
		Vetoes: vetoes,
	}
	return chosen, true, reason
}

// Release marks a request complete for the in-flight counter.
func (p *Pool) Release(sc health.Scope) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.inFlight[sc] > 0 {
		p.inFlight[sc]--
	}
}

// ReportOutcome feeds the scorer: success raises the Beta posterior;
// failure lowers it. Fail-open applies (score floors at a small prior, so
// a failing endpoint is demoted, never exiled).
func (p *Pool) ReportOutcome(sc health.Scope, success bool, latency time.Duration) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.score.Report(sc, success, latency)
}

// sampleProportional picks a challenger weighted by cap share — the
// capacity-proportional sampling the heterogeneity theory requires.
func (p *Pool) sampleProportional(family string, eligible []Endpoint, exclude health.Scope) Endpoint {
	var weights []float64
	var cands []Endpoint
	for _, e := range eligible {
		if e.Scope == exclude {
			continue
		}
		w := 1.0
		if v, ok := e.Weights["rpm"]; ok && v > 0 {
			w = v
		}
		weights = append(weights, w)
		cands = append(cands, e)
	}
	if len(cands) == 0 {
		// only the primary exists: P2C degenerates — return a sentinel
		// identical to primary so the caller's comparison is a no-op
		for _, e := range eligible {
			if e.Scope == exclude {
				return e
			}
		}
		return Endpoint{}
	}
	total := 0.0
	for _, w := range weights {
		total += w
	}
	r := p.rng.Float64() * total
	for i, w := range weights {
		r -= w
		if r <= 0 {
			return cands[i]
		}
	}
	return cands[len(cands)-1]
}

// Chain returns the failover order for a family: health-eligible first
// (score-ranked), blocked last — the walk's candidate sequence.
func (p *Pool) Chain(family string) []Endpoint {
	p.mu.Lock()
	defer p.mu.Unlock()
	members := p.members[family]
	type scored struct {
		e       Endpoint
		score   float64
		blocked bool
	}
	var list []scored
	for _, e := range members {
		blocked, _, _ := p.machine.Blocks(e.Scope)
		list = append(list, scored{e, p.score.Value(e.Scope), blocked})
	}
	sort.SliceStable(list, func(i, j int) bool {
		if list[i].blocked != list[j].blocked {
			return list[j].blocked // unblocked first
		}
		return list[i].score > list[j].score
	})
	out := make([]Endpoint, 0, len(list))
	for _, s := range list {
		out = append(out, s.e)
	}
	return out
}
