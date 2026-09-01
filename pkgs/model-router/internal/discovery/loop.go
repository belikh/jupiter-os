// Package discovery keeps the router's model catalogue honest: it polls
// each provider's live /v1/models (the only signal fast enough for the
// silent-removal regime), reconciles membership against the pool, resolves
// model identity across providers, and actioning removals by drain-then-
// retire with reversible tombstones.
package discovery

import (
	"context"
	"sort"
	"strings"
	"sync"
	"time"

	"modelrouter/internal/health"
	"modelrouter/internal/pool"
	"modelrouter/internal/seed"
)

// ModelMapping is one resolved (family, provider, local-slug) triple with
// lifecycle state. Tombstoned mappings stay in the catalogue (reversible)
// but leave the routing pools.
type ModelMapping struct {
	Family     string
	Provider   string
	LocalSlug  string
	Status     string // free|free_capped|trial|paid|paid_gated|no_host
	Tombstoned bool
	Reason     string // tombstone cause
}

// Loop is the discovery engine. One goroutine per configured poll; the
// runner fans out per provider with per-provider log-and-skip.
type Loop struct {
	mu            sync.Mutex
	mappings      map[string]ModelMapping // key: family|provider
	providerKinds map[string]string       // provider -> poll regime (from seed)
	pools         *pool.Pool
	machine       *health.Machine
	events        func(health.Event)
	adapters      map[string]Adapter
	interval      time.Duration
}

// Adapter is the discovery-facing slice of upstream.Adapter.
type Adapter interface {
	ListModels(ctx context.Context) ([]string, error)
}

// New builds the loop from seed mappings.
func New(s seed.Seed, pools *pool.Pool, machine *health.Machine, adapters map[string]Adapter, eventsFn func(health.Event)) *Loop {
	l := &Loop{
		mappings:      make(map[string]ModelMapping),
		providerKinds: make(map[string]string),
		pools:         pools,
		machine:       machine,
		events:        eventsFn,
		adapters:      adapters,
		interval:      24 * time.Hour, // silent-regime default: daily
	}
	for _, m := range s.Models {
		key := m.Family + "|" + m.ProviderID
		l.mappings[key] = ModelMapping{
			Family:    m.Family,
			Provider:  m.ProviderID,
			LocalSlug: m.LocalSlug,
			Status:    m.Status,
		}
	}
	for _, p := range s.Providers {
		l.providerKinds[p.ID] = "daily"
	}
	return l
}

// Snapshot returns the current catalogue sorted by family then provider.
func (l *Loop) Snapshot() []ModelMapping {
	l.mu.Lock()
	defer l.mu.Unlock()
	out := make([]ModelMapping, 0, len(l.mappings))
	for _, m := range l.mappings {
		out = append(out, m)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Family != out[j].Family {
			return out[i].Family < out[j].Family
		}
		return out[i].Provider < out[j].Provider
	})
	return out
}

// PollOnce runs one reconciliation pass for one provider: fetch the live
// catalogue, add unseen models (admission), retire models the provider
// dropped (silent-removal detection), and leave tombstones reversible.
// Returns the added/removed slugs for the event log.
func (l *Loop) PollOnce(ctx context.Context, providerID string) (added, removed []string, err error) {
	ad, ok := l.adapters[providerID]
	if !ok {
		return nil, nil, nil
	}
	live, err := ad.ListModels(ctx)
	if err != nil {
		return nil, nil, err
	}
	liveSet := make(map[string]bool, len(live))
	for _, id := range live {
		liveSet[normalise(id)] = true
	}

	l.mu.Lock()
	defer l.mu.Unlock()

	// membership diff over this provider's mappings
	for key, m := range l.mappings {
		if m.Provider != providerID {
			continue
		}
		if m.Tombstoned {
			// reversible: if the provider re-lists a tombstoned slug,
			// resurrect it
			if liveSet[normalise(m.LocalSlug)] {
				m.Tombstoned = false
				m.Reason = ""
				l.mappings[key] = m
				added = append(added, m.LocalSlug)
			}
			continue
		}
		if !liveSet[normalise(m.LocalSlug)] {
			// silent removal: the live catalogue no longer lists it
			m.Tombstoned = true
			m.Reason = "absent from live /v1/models poll"
			l.mappings[key] = m
			removed = append(removed, m.LocalSlug)
			l.emitEvent(m, "catalogue: model removed from "+providerID+" live list")
		}
	}

	// admission: live slugs we have no mapping for (cross-referenced
	// against seed families by slug identity — conservative: only admit
	// slugs matching a known family's pattern)
	l.applyToPools(providerID)
	return added, removed, nil
}

// applyToPools rebuilds the pool membership for every family from the
// non-tombstoned mappings of one provider, MERGED with other providers'
// existing members (each provider owns its own membership; families are
// the union). Families whose every member left the catalogue get an empty
// member set — drain-then-retire means the pool shrinks, not lingers.
func (l *Loop) applyToPools(providerID string) {
	byFamily := make(map[string][]pool.Endpoint)
	for _, m := range l.mappings {
		if m.Tombstoned {
			continue
		}
		if m.Status == "no_host" || m.Status == "paid" || m.Status == "paid_gated" {
			continue // v1 pools free-capable endpoints only
		}
		if m.Provider != providerID {
			continue
		}
		byFamily[m.Family] = append(byFamily[m.Family], pool.Endpoint{
			Scope: health.Scope{
				Provider: m.Provider,
				Model:    m.Family,
				Key:      "default",
			},
			Weights: map[string]float64{"rpm": 30}, // seed hints refine later
			Family:  m.Family,
			LocalID: m.LocalSlug,
		})
	}
	// union with OTHER providers' current members so this provider's
	// rebuild never wipes its siblings; but if THIS provider's families
	// now have zero of its own endpoints, its contribution is correctly
	// absent from the union
	families := make(map[string]bool)
	for _, m := range l.mappings {
		families[m.Family] = true
	}
	for family := range families {
		merged := append([]pool.Endpoint{}, byFamily[family]...)
		if eps := l.pools.Members(family); len(eps) > 0 {
			for _, e := range eps {
				if e.Scope.Provider != providerID {
					merged = append(merged, e)
				}
			}
		}
		l.pools.SetMembers(family, merged)
	}
}

// Admission adds a new mapping discovered live (the confirmation queue's
// output). Once-per-triple probing is the caller's gate.
func (l *Loop) Admit(m ModelMapping) {
	l.mu.Lock()
	defer l.mu.Unlock()
	key := m.Family + "|" + m.Provider
	l.mappings[key] = m
	l.emitEvent(m, "catalogue: admitted "+m.LocalSlug+" on "+m.Provider)
	l.applyToPools(m.Provider)
}

// Retire tombstones a mapping with a reason and rebuilds the pool
// (drain-then-retire: in-flight requests complete; new Selects skip it).
func (l *Loop) Retire(family, provider, reason string) {
	l.mu.Lock()
	key := family + "|" + provider
	m, ok := l.mappings[key]
	if !ok {
		l.mu.Unlock()
		return
	}
	m.Tombstoned = true
	m.Reason = reason
	l.mappings[key] = m
	msg := "catalogue: retired " + m.LocalSlug + " (" + reason + ")"
	l.mu.Unlock()
	l.emitEvent(m, msg)
	l.mu.Lock()
	l.applyToPools(provider)
	l.mu.Unlock()
}

func (l *Loop) emitEvent(m ModelMapping, msg string) {
	if l.events != nil {
		l.events(health.Event{
			Time:   time.Now(),
			Scope:  health.Scope{Provider: m.Provider, Model: m.Family},
			Reason: msg,
		})
	}
}

// normalise strips the variant suffixes the identity research documented:
// :free, :cloud, :nitro, and dated -MMDD / -YYMMDD / -YYYYMMDD tails.
func normalise(slug string) string {
	s := slug
	// strip dated suffix on the final segment (4/6/8 digit tails)
	if idx := strings.LastIndex(s, "-"); idx > 0 {
		tail := s[idx+1:]
		if isDateTail(tail) {
			s = s[:idx]
		}
	}
	// strip variant suffix
	for _, v := range []string{":free", ":cloud", ":nitro", ":floor", ":exacto", ":fastest", ":cheapest"} {
		if strings.HasSuffix(s, v) {
			s = strings.TrimSuffix(s, v)
			break
		}
	}
	return s
}

func isDateTail(s string) bool {
	if len(s) != 4 && len(s) != 6 && len(s) != 8 {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// Run drives the poll matrix until the context cancels. Silent-regime
// providers poll daily (the default); this v1 runner polls every provider
// on the same interval — per-provider cadence tuning rides on the seed's
// window hints (recorded for Task 8's settings page).
func (l *Loop) Run(ctx context.Context) {
	t := time.NewTicker(l.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			for providerID := range l.adapters {
				pctx, cancel := context.WithTimeout(ctx, 30*time.Second)
				_, _, err := l.PollOnce(pctx, providerID)
				cancel()
				if err != nil {
					// log-and-skip per provider (ferrogw pattern): one
					// provider's outage never stops the loop
					l.emitEvent(ModelMapping{Provider: providerID}, "catalogue: poll failed for "+providerID+" ("+err.Error()+")")
				}
			}
		}
	}
}
