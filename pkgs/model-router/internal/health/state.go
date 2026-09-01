// Package health tracks per-(provider, model, key) endpoint health as four
// orthogonal states, each carrying a TTL, a provenance (our guess or the
// provider's own statement) and a human-readable reason for the dashboard.
package health

import (
	"strings"
	"sync"
	"time"
)

// Scope identifies what a health state applies to. An empty Key means the
// state is account-level for that provider and model.
type Scope struct {
	Provider string
	Model    string
	Key      string
}

// State is one orthogonal health dimension. A scope can carry several at
// once — a rate-limit cooldown and an open circuit are different facts with
// different expiries.
type State int

const (
	RateLimit State = iota
	Quota
	Circuit
	Terminal
)

// Provenance records whether a cooldown was our heuristic guess or the
// provider's authoritative statement. Only heuristic cooldowns may be probed
// early; authoritative ones wait for their stated clock.
type Provenance int

const (
	Heuristic Provenance = iota
	Authoritative
)

// billingMarker — reasons containing this marker take the 24-hour billing
// escalation tier rather than the rate-limit ladder. Defined here so the
// classifier (classify.go) and callers agree on the convention.
const billingMarker = "billing"

// Escalation ladder for repeated heuristic quota exhaustion within the same
// window day. The corpus converged on these steps.
var escalateQuota = []time.Duration{
	2 * time.Minute,
	10 * time.Minute,
	time.Hour,
	24 * time.Hour,
}

// transientRateLimitTTL is the heuristic cooldown for a rate-limit hit that
// carries no authoritative retry hint.
const transientRateLimitTTL = 90 * time.Second

// billingTTL is the cooldown for billing-tier rejections masquerading as
// rate limits (the lying-code class).
const billingTTL = 24 * time.Hour

type stateEntry struct {
	expiresAt  time.Time
	provenance Provenance
	reason     string
}

type escalationKey struct {
	kind   State
	window string // the window day the repeats count within
}

// Machine holds active health states per scope. Safe for concurrent use.
// Expiry is driven by Tick(now) so tests can move time without sleeping.
type Machine struct {
	mu      sync.Mutex
	now     time.Time
	states  map[Scope]map[State]stateEntry
	repeats map[Scope]map[escalationKey]int
	events  []Event
	hook    func(Event)
}

// NewMachine returns a Machine with its clock at the Unix epoch; call Tick
// before use in production so expiries compute against real time.
func NewMachine() *Machine {
	return &Machine{
		states:  make(map[Scope]map[State]stateEntry),
		repeats: make(map[Scope]map[escalationKey]int),
	}
}

// Set records a state for the scope. TTLs escalate for repeated heuristic
// quota exhaustion within the same window day; authoritative provenance
// overrides any ladder. Every Set appends an event.
func (m *Machine) Set(sc Scope, st State, ttl time.Duration, prov Provenance, reason string) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if prov == Heuristic && st == Quota {
		ttl = m.escalate(sc, st, reason, ttl)
	}
	if prov == Heuristic && st == RateLimit && strings.Contains(reason, billingMarker) {
		// billing-tier rejection misreported as a rate limit: flat 24h
		ttl = billingTTL
	}

	entry := stateEntry{expiresAt: m.now.Add(ttl), provenance: prov, reason: reason}
	if m.states[sc] == nil {
		m.states[sc] = make(map[State]stateEntry)
	}
	m.states[sc][st] = entry
	m.record(sc, st, reason, prov, "set")
}

// escalate walks the quota ladder on repeats within the same window day.
// The first hit takes the caller's TTL; each repeat takes the next rung.
func (m *Machine) escalate(sc Scope, st State, reason string, base time.Duration) time.Duration {
	day := m.now.UTC().Format("2006-01-02")
	k := escalationKey{kind: st, window: day}
	if m.repeats[sc] == nil {
		m.repeats[sc] = make(map[escalationKey]int)
	}
	n := m.repeats[sc][k]
	m.repeats[sc][k] = n + 1
	if n >= len(escalateQuota) {
		return escalateQuota[len(escalateQuota)-1]
	}
	// The first exhaustion of a window day keeps the caller's TTL (the
	// classified quota TTL, e.g. until the stated reset); repeats climb.
	if n == 0 {
		return base
	}
	return escalateQuota[n-1]
}

// Blocks reports whether any active (unexpired) state exists for the scope,
// with the earliest-expiring state's reason and expiry. Expired entries are
// pruned as a side effect.
func (m *Machine) Blocks(sc Scope) (blocked bool, why string, until time.Time) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.blocksLocked(sc)
}

func (m *Machine) blocksLocked(sc Scope) (bool, string, time.Time) {
	entries := m.states[sc]
	if len(entries) == 0 {
		return false, "", time.Time{}
	}
	var best *stateEntry
	for st, e := range entries {
		if !m.now.Before(e.expiresAt) {
			delete(entries, st) // expired — prune
			continue
		}
		if best == nil || e.expiresAt.Before(best.expiresAt) {
			cp := e
			best = &cp
		}
	}
	if len(entries) == 0 {
		delete(m.states, sc)
	}
	if best == nil {
		return false, "", time.Time{}
	}
	return true, best.reason, best.expiresAt
}

// Tick advances the machine clock and prunes expired entries.
func (m *Machine) Tick(now time.Time) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.now = now
	for sc, entries := range m.states {
		for st, e := range entries {
			if !now.Before(e.expiresAt) {
				delete(entries, st)
			}
		}
		if len(entries) == 0 {
			delete(m.states, sc)
		}
	}
}

// Clear removes one state from a scope (for example a probe success
// clearing a heuristic circuit).
func (m *Machine) Clear(sc Scope, st State) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if entries, ok := m.states[sc]; ok {
		if e, had := entries[st]; had {
			delete(entries, st)
			if len(entries) == 0 {
				delete(m.states, sc)
			}
			m.record(sc, st, e.reason, e.provenance, "clear")
		}
	}
}

// Success clears all escalation history for the scope — any successful
// request resets the ladder.
func (m *Machine) Success(sc Scope) {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.repeats, sc)
	m.record(sc, State(-1), "success", Heuristic, "success")
}

// ProbeEligible reports whether a heuristic state may be probed early.
// Authoritative states are never probe-eligible — the provider's stated
// clock governs.
func (m *Machine) ProbeEligible(sc Scope, st State) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	e, ok := m.states[sc][st]
	if !ok {
		return false
	}
	return e.provenance == Heuristic && m.now.Before(e.expiresAt)
}

// AllBlocked reports whether every scope serving the given model is blocked,
// letting the selection layer's fail-open bypass check stay cheap. Scopes
// for other models are ignored; an empty matching set is not "all blocked".
func (m *Machine) AllBlocked(scopes []Scope, model string) bool {
	matched := 0
	for _, sc := range scopes {
		if sc.Model != model {
			continue
		}
		matched++
		if blocked, _, _ := m.blocksLocked(sc); !blocked {
			return false
		}
	}
	return matched > 0
}
