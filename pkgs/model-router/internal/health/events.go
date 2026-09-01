package health

import "time"

// Event records every health transition with its reason — the dashboard's
// "why is this endpoint down" trail.
type Event struct {
	Time       time.Time
	Scope      Scope
	State      State
	Reason     string
	Provenance Provenance
	Kind       string // "set", "clear", "success"
}

// eventRingSize bounds the in-memory trail.
const eventRingSize = 512

// record appends to the ring and pushes through the persistence hook when
// one is wired (nil-safe).
func (m *Machine) record(sc Scope, st State, reason string, prov Provenance, kind string) {
	ev := Event{
		Time:       m.now,
		Scope:      sc,
		State:      st,
		Reason:     reason,
		Provenance: prov,
		Kind:       kind,
	}
	m.events = append(m.events, ev)
	if len(m.events) > eventRingSize {
		// drop the oldest half to amortise the copy cost
		m.events = m.events[len(m.events)-eventRingSize:]
	}
	if m.hook != nil {
		m.hook(ev)
	}
}

// SetEventHook wires an append-only persistence sink (the events store,
// wired in the web task). Nil-safe: nil disables.
func (m *Machine) SetEventHook(fn func(Event)) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.hook = fn
}

// Events returns the most recent events, newest first.
func (m *Machine) Events(limit int) []Event {
	m.mu.Lock()
	defer m.mu.Unlock()
	if limit <= 0 || limit > len(m.events) {
		limit = len(m.events)
	}
	out := make([]Event, 0, limit)
	for i := len(m.events) - 1; i >= 0 && len(out) < limit; i-- {
		out = append(out, m.events[i])
	}
	return out
}
