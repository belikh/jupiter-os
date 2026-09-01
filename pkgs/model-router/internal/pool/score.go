package pool

import (
	"math"
	"math/rand"
	"sync"
	"time"

	"modelrouter/internal/health"
)

// Score is the Thompson-Beta scoring base: each endpoint holds a Beta
// posterior over reliability (successes + 1, failures + 1 prior), sampled
// per selection. Unseen endpoints carry genuine uncertainty (the uniform
// prior), so cold-start endpoints get tried rather than shunned; repeated
// failures demote an endpoint's sampled score without ever removing it —
// demote-not-drop, the corpus's anti-oscillation rule.
type Score struct {
	mu      sync.Mutex
	alpha   map[health.Scope]float64
	beta    map[health.Scope]float64
	latency map[health.Scope]float64 // EWMA of successful latency
	rng     *rand.Rand
}

func NewScore(src rand.Source) *Score {
	return &Score{
		alpha:   make(map[health.Scope]float64),
		beta:    make(map[health.Scope]float64),
		latency: make(map[health.Scope]float64),
		rng:     rand.New(src),
	}
}

// Report updates the posterior. Fail-open floors: alpha never drops below
// 0.5 so a failing endpoint is demoted, never exiled.
func (s *Score) Report(sc health.Scope, success bool, latency time.Duration) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.alpha[sc] == 0 && s.beta[sc] == 0 {
		s.alpha[sc] = 1
		s.beta[sc] = 1
	}
	if success {
		s.alpha[sc]++
		if latency > 0 {
			// EWMA with 0.3 smoothing
			ms := float64(latency.Milliseconds())
			if s.latency[sc] == 0 {
				s.latency[sc] = ms
			} else {
				s.latency[sc] = 0.7*s.latency[sc] + 0.3*ms
			}
		}
	} else {
		s.beta[sc]++
		if s.alpha[sc] < 0.5 {
			s.alpha[sc] = 0.5
		}
	}
}

// Sample draws a Thompson sample: a Beta-distributed reliability estimate.
func (s *Score) Sample(sc health.Scope) float64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	a := s.alpha[sc]
	b := s.beta[sc]
	if a == 0 && b == 0 {
		a, b = 1, 1 // uniform prior: genuine uncertainty
	}
	return betaSample(s.rng, a, b)
}

// Value is the posterior mean (used for chain ranking, no sampling).
func (s *Score) Value(sc health.Scope) float64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	a := s.alpha[sc]
	b := s.beta[sc]
	if a+b == 0 {
		return 0.5
	}
	return a / (a + b)
}

// AdjustOrder applies demote-not-drop to a chosen candidate: a clearly-weak
// chosen sample (below 0.45) is swapped for a clearly-strong challenger
// (above 0.65) — cold-start noise on EITHER side never reorders, because
// a candidate that is merely unknown must not displace DRR's capacity share.
func (s *Score) AdjustOrder(family string, chosen *Endpoint, eligible []Endpoint, inFlight func(health.Scope) int) {
	chosenSample := s.Sample(chosen.Scope)
	if chosenSample >= 0.45 {
		return // the choice is healthy: sampling noise never reorders
	}
	bestSample := chosenSample
	var best Endpoint
	found := false
	for _, e := range eligible {
		if e.Scope == chosen.Scope {
			continue
		}
		if sm := s.Sample(e.Scope); sm > 0.65 && sm > bestSample {
			bestSample = sm
			best = e
			found = true
		}
	}
	if found {
		*chosen = best
	}
}

// betaSample draws one sample from Beta(a, b) via two gamma draws.
func betaSample(rng *rand.Rand, a, b float64) float64 {
	x := gammaSample(rng, a)
	y := gammaSample(rng, b)
	if x+y == 0 {
		return 0.5
	}
	return x / (x + y)
}

// gammaSample uses Marsaglia-Tsang for shape >= 1, boosting below.
func gammaSample(rng *rand.Rand, shape float64) float64 {
	if shape < 1 {
		// boost: Gamma(shape) = Gamma(shape+1) * U^(1/shape)
		u := rng.Float64()
		g := gammaSample(rng, shape+1)
		return g * math.Pow(u, 1/shape)
	}
	d := shape - 1.0/3.0
	c := 1.0 / math.Sqrt(9.0*d)
	for {
		x := rng.NormFloat64()
		v := 1.0 + c*x
		if v <= 0 {
			continue
		}
		v = v * v * v
		u := rng.Float64()
		if u < 1-0.0331*x*x*x*x {
			return d * v
		}
		if u < math.Exp(-0.5*x*x) && math.Log(u) < 0.5*x*x+d*(1-v+math.Log(v)) {
			return d * v
		}
	}
}
