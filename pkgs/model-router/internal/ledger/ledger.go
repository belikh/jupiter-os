// Package ledger tracks per-(provider, model, key) quota consumption across
// four window shapes, learns enforced ceilings from responses, and closes
// the check-then-act race with in-flight leases.
package ledger

import (
	"sync"
	"time"

	"modelrouter/internal/health"
)

// WindowKind is the reset semantics a provider uses, from the research
// corpus's per-provider typology.
type WindowKind int

const (
	RollingHeaders       WindowKind = iota // Groq: countdown headers, replenish continuously
	FixedPacificMidnight                   // Google AI Studio: fixed daily reset at midnight Pacific
	UTCMidnightShared                      // OpenRouter: account-wide daily budget, resets 00:00 UTC
	ContinuousBucket                       // Cerebras: token-bucket refill, never a fixed reset
	Session5h7d                            // Ollama Cloud / Z.ai: 5-hour session + 7-day weekly
	CreditExpiry                           // credits that expire (Cerebras trial) or recur (HF monthly)
)

// Standard dimension names (mirroring seed cap kinds and ParseCeilings).
const (
	DimRPM         = "rpm"
	DimRPD         = "rpd"
	DimTPM         = "tpm"
	DimTPD         = "tpd"
	DimNeuronsDay  = "neurons_day"
	DimCreditsMth  = "credits_month"
	DimConcurrency = "concurrency"
)

// Lease is an in-flight reservation: created by Reserve, closed by Commit
// (success — spend stands) or Release (failure — budget returned).
type Lease struct {
	scope   health.Scope
	dims    map[string]float64
	created time.Time
}

// Ledger is safe for concurrent use. The hot path is entirely in-memory;
// persistence (batched flush) arrives with the wiring task.
type Ledger struct {
	mu          sync.Mutex
	ceilings    map[health.Scope]map[string]float64
	spent       map[health.Scope]map[string]float64
	windowStart map[health.Scope]time.Time
	kinds       map[health.Scope]WindowKind
	pacific     *time.Location
	now         func() time.Time
}

// New returns an empty Ledger.
func New() *Ledger {
	pac, err := time.LoadLocation("America/Los_Angeles")
	if err != nil {
		pac = time.UTC
	}
	return &Ledger{
		ceilings:    make(map[health.Scope]map[string]float64),
		spent:       make(map[health.Scope]map[string]float64),
		windowStart: make(map[health.Scope]time.Time),
		kinds:       make(map[health.Scope]WindowKind),
		pacific:     pac,
		now:         time.Now,
	}
}

// SetNow overrides the clock (tests).
func (l *Ledger) SetNow(fn func() time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.now = fn
}

// ConfigureScope installs a scope's window kind and initial ceilings.
// Dimension keys mirror the seed cap kind strings.
func (l *Ledger) ConfigureScope(sc health.Scope, kind WindowKind, caps map[string]float64) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.windowStart[sc].IsZero() {
		l.windowStart[sc] = l.now()
	}
	l.kinds[sc] = kind
	if l.ceilings[sc] == nil {
		l.ceilings[sc] = make(map[string]float64)
	}
	for dim, val := range caps {
		if existing, ok := l.ceilings[sc][dim]; !ok || existing == 0 {
			l.ceilings[sc][dim] = val
		}
	}
}

// Reserve checks every dimension against remaining headroom and, when all
// pass, takes the units immediately — closing the check-then-act race.
// Returns the lease and true, or nil, false and the blocking dimension.
func (l *Ledger) Reserve(sc health.Scope, cost map[string]float64) (*Lease, bool, string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.rollWindow(sc)
	for dim, units := range cost {
		if units <= 0 {
			continue
		}
		ceiling := l.ceilings[sc][dim]
		if ceiling == 0 {
			continue // unlearned dimension: no enforced cap
		}
		if l.spent[sc][dim]+units > ceiling {
			return nil, false, dim
		}
	}
	if l.spent[sc] == nil {
		l.spent[sc] = make(map[string]float64)
	}
	for dim, units := range cost {
		l.spent[sc][dim] += units
	}
	return &Lease{scope: sc, dims: cost, created: l.now()}, true, ""
}

// Commit finalises a lease: the reserved units stand (already spent).
func (l *Ledger) Commit(lease *Lease) {}

// Release returns a lease's units (the request failed before the provider
// could count it).
func (l *Ledger) Release(lease *Lease) {
	if lease == nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	for dim, units := range lease.dims {
		if l.spent[lease.scope] != nil {
			l.spent[lease.scope][dim] -= units
			if l.spent[lease.scope][dim] < 0 {
				l.spent[lease.scope][dim] = 0
			}
		}
	}
}

// LearnFromResponse applies ceiling hints and reset stamps parsed from a
// provider response. Monotone-conservative: fills unset dimensions, lowers
// existing ones, never raises. A reset_at hint clears spent counters (the
// provider's own reset fired).
func (l *Ledger) LearnFromResponse(sc health.Scope, hints []health.CeilingHint) {
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, h := range hints {
		if h.Dimension == "reset_at" {
			l.spent[sc] = make(map[string]float64)
			l.windowStart[sc] = l.now()
			continue
		}
		if l.ceilings[sc] == nil {
			l.ceilings[sc] = make(map[string]float64)
		}
		if existing, ok := l.ceilings[sc][h.Dimension]; !ok || existing == 0 || h.Value < existing {
			l.ceilings[sc][h.Dimension] = h.Value
		}
	}
}

// NextReset reports when the scope's window rolls, per its kind.
func (l *Ledger) NextReset(sc health.Scope) (time.Time, WindowKind) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.rollWindow(sc)
	kind := l.kinds[sc]
	now := l.now()
	switch kind {
	case FixedPacificMidnight:
		pn := now.In(l.pacific)
		return time.Date(pn.Year(), pn.Month(), pn.Day()+1, 0, 0, 0, 0, l.pacific), kind
	case UTCMidnightShared:
		un := now.UTC()
		return time.Date(un.Year(), un.Month(), un.Day()+1, 0, 0, 0, 0, time.UTC), kind
	case Session5h7d:
		start := l.windowStart[sc]
		if start.IsZero() {
			start = now
		}
		return start.Add(5 * time.Hour), kind
	default: // RollingHeaders, ContinuousBucket, CreditExpiry, unset
		return now.Truncate(time.Minute).Add(time.Minute), kind
	}
}

// HeadroomRatio is the smallest remaining fraction across capped
// dimensions — the selection layer's probe-budget gate input.
func (l *Ledger) HeadroomRatio(sc health.Scope) float64 {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.rollWindow(sc)
	worst := 1.0
	seen := false
	for dim, ceiling := range l.ceilings[sc] {
		if ceiling <= 0 {
			continue
		}
		frac := (ceiling - l.spent[sc][dim]) / ceiling
		if frac < worst {
			worst = frac
		}
		seen = true
	}
	if !seen {
		return 1.0
	}
	return worst
}

// rollWindow resets spent counters when a boundary has passed.
func (l *Ledger) rollWindow(sc health.Scope) {
	kind := l.kinds[sc]
	start := l.windowStart[sc]
	if start.IsZero() {
		l.windowStart[sc] = l.now()
		return
	}
	now := l.now()
	switch kind {
	case FixedPacificMidnight:
		if now.In(l.pacific).Day() != start.In(l.pacific).Day() {
			l.spent[sc] = make(map[string]float64)
			l.windowStart[sc] = now
		}
	case UTCMidnightShared:
		if now.UTC().Day() != start.UTC().Day() {
			l.spent[sc] = make(map[string]float64)
			l.windowStart[sc] = now
		}
	case Session5h7d:
		if !now.Before(start.Add(5 * time.Hour)) {
			l.spent[sc] = make(map[string]float64)
			l.windowStart[sc] = now
		}
	case RollingHeaders, ContinuousBucket:
		if !now.Before(start.Truncate(time.Minute).Add(time.Minute)) {
			l.spent[sc] = make(map[string]float64)
			l.windowStart[sc] = now
		}
	case CreditExpiry:
		if !now.Before(start.Add(24 * time.Hour)) {
			l.spent[sc] = make(map[string]float64)
			l.windowStart[sc] = now
		}
	}
}
