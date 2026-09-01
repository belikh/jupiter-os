package pool

import (
	"sync"

	"modelrouter/internal/health"
)

// DRR is a deficit-round-robin scheduler weighted by cap share. Each family
// owns a queue; each endpoint accrues a credit at its weight per round, and
// the endpoint with the largest accumulated deficit-weight balance serves.
// This is the capacity-proportional fairness the corpus converges on
// (OmniRoute's Quota-Share + NVIDIA Dynamo's token-cost DRR): a 30-RPM
// endpoint earns ~3x the service share of a 10-RPM one without starving it.
type DRR struct {
	mu      sync.Mutex
	queues  map[string][]drrEntry
	credits map[health.Scope]float64
}

type drrEntry struct {
	scope  health.Scope
	weight float64
}

func NewDRR() *DRR {
	return &DRR{
		queues:  make(map[string][]drrEntry),
		credits: make(map[health.Scope]float64),
	}
}

// Configure installs the endpoint set and cap-share weights for a family.
// Weight derives from the endpoint's rpm cap share (fallback 1.0).
func (d *DRR) Configure(family string, endpoints []Endpoint) {
	d.mu.Lock()
	defer d.mu.Unlock()
	q := make([]drrEntry, 0, len(endpoints))
	for _, e := range endpoints {
		w := 1.0
		if v, ok := e.Weights["rpm"]; ok && v > 0 {
			w = v
		}
		q = append(q, drrEntry{scope: e.Scope, weight: w})
	}
	d.queues[family] = q
}

// Next returns the endpoint whose turn it is. Every eligible endpoint
// accrues weight as credit each call; the highest balance serves and its
// balance drops by the total round weight — classic DRR.
func (d *DRR) Next(family string, eligible []Endpoint) (Endpoint, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()

	if len(eligible) == 0 {
		return Endpoint{}, false
	}

	// accrue: every eligible endpoint earns its weight
	total := 0.0
	for _, e := range eligible {
		w := 1.0
		if v, ok := e.Weights["rpm"]; ok && v > 0 {
			w = v
		}
		d.credits[e.Scope] += w
		total += w
	}

	// serve: highest balance wins, pays the round total
	var best Endpoint
	bestBal := -1.0
	for _, e := range eligible {
		if d.credits[e.Scope] > bestBal {
			bestBal = d.credits[e.Scope]
			best = e
		}
	}
	d.credits[best.Scope] -= total
	if d.credits[best.Scope] < 0 {
		d.credits[best.Scope] = 0
	}
	return best, true
}
