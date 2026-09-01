package upstream

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"sync"
	"time"

	"modelrouter/internal/health"
	"modelrouter/internal/ledger"
	"modelrouter/internal/pool"
)

// WalkConfig carries the corpus-tuned walk constants.
type WalkConfig struct {
	PerAttemptHedge time.Duration // 20s: stall-abort budget per attempt
	TotalBudget     time.Duration // 45s: whole-chain pre-commit budget
	IdleTimeout     time.Duration // 30s: post-commit content-clock watchdog
	HardCeiling     time.Duration // 300s: stream hard ceiling
}

func DefaultWalkConfig() WalkConfig {
	return WalkConfig{
		PerAttemptHedge: 20 * time.Second,
		TotalBudget:     45 * time.Second,
		IdleTimeout:     30 * time.Second,
		HardCeiling:     300 * time.Second,
	}
}

// Walk executes a chat request through a pool's endpoint chain: failover
// stays possible until the first content-bearing delta is emitted to the
// client (the commit); after commit, failures terminate honestly with an
// enum-mapped error event — a second provider is never spliced into a
// half-delivered answer.
type Walk struct {
	cfg     WalkConfig
	pools   *pool.Pool
	led     *ledger.Ledger
	machine *health.Machine
	adapter func(provider string) Adapter // provider registry
}

func NewWalk(pools *pool.Pool, led *ledger.Ledger, machine *health.Machine, adapterFn func(string) Adapter) *Walk {
	return &Walk{cfg: DefaultWalkConfig(), pools: pools, led: led, machine: machine, adapter: adapterFn}
}

// ErrAllEndpointsFailed is returned when the chain exhausts pre-commit.
var ErrAllEndpointsFailed = errors.New("all endpoints failed before any content was delivered")

// ErrCommitted is returned post-commit when the stream terminates
// dishonestly: the client already received content, so the facade maps
// this to an in-band enum-legal error termination, never a splice.
var ErrCommitted = errors.New("stream failed after content was committed")

// EmitFunc receives parsed SSE events destined for the client.
type EmitFunc func(event SSEEvent) error

// Run walks the chain for the model family. The emit callback is the commit
// boundary: the first content-bearing event emitted marks the response as
// committed and failover is closed from that instant.
func (w *Walk) Run(ctx context.Context, family string, req Request, emit EmitFunc) error {
	// startCtx bounds the whole pre-commit phase (hedge budget included)
	startCtx, cancelStart := context.WithTimeout(ctx, w.cfg.TotalBudget)
	defer cancelStart()

	chain := w.pools.Chain(family)
	if len(chain) == 0 {
		return fmt.Errorf("no endpoints for %s", family)
	}

	committed := false
	var committedMu sync.Mutex
	lastContent := time.Now()

	for _, ep := range chain {
		if startCtx.Err() != nil {
			break // budget exhausted
		}
		// reserve quota dimensions for this attempt (rpm + rpd; token
		// costs are learned post-hoc from the provider's usage events)
		sc := ep.Scope
		lease, ok, _ := w.led.Reserve(sc, map[string]float64{"rpm": 1, "rpd": 1})
		if !ok {
			continue // quota exhausted pre-flight: next hop
		}

		attemptCtx, cancelAttempt := context.WithTimeout(startCtx, w.cfg.PerAttemptHedge)
		ad := w.adapter(ep.Scope.Provider)
		if ad == nil {
			cancelAttempt()
			w.led.Release(lease)
			continue
		}
		res, err := ad.Start(attemptCtx, ScopeID{Provider: ep.Scope.Provider, Model: ep.LocalID, Key: ep.Scope.Key}, req)
		if err != nil || res == nil || res.Status < 200 || res.Status >= 300 {
			// pre-commit failure: classify, learn, health-update, release
			w.recordFailure(sc, res, err, attemptCtx)
			ad.Close(res)
			cancelAttempt()
			w.led.Release(lease)
			continue
		}

		// stream: parse with a stall watchdog; commit on first content
		streamErr := w.stream(attemptCtx, res, emit, &committed, &committedMu, &lastContent, sc)
		ad.Close(res)
		cancelAttempt()

		if streamErr == nil {
			// success: outcome, success-health, ledger stands
			w.pools.ReportOutcome(sc, true, 0)
			w.machine.Success(sc)
			return nil
		}
		if committedVal(&committed, &committedMu) {
			// committed: honest termination, no splice, no retry
			w.pools.ReportOutcome(sc, false, 0)
			return ErrCommitted
		}
		// pre-commit stream failure: classify, release lease, next hop
		w.recordStreamFailure(sc, streamErr)
		w.led.Release(lease)
		continue
	}

	if committedVal(&committed, &committedMu) {
		return ErrCommitted
	}
	return ErrAllEndpointsFailed
}

// stream parses the SSE response, emitting to the client. The first
// content-bearing delta flips committed; the watchdogs guard the
// post-commit stream (idle content clock + hard ceiling). Role-only
// chunks, pings and comments do NOT commit — the tightened rule.
func (w *Walk) stream(ctx context.Context, res *StartResult, emit EmitFunc, committed *bool, mu *sync.Mutex, lastContent *time.Time, sc health.Scope) error {
	rdr := res.Resp.Body

	// stall watchdog: a timer that aborts the stream when no content has
	// arrived within the idle timeout (pre-commit: per-attempt hedge
	// already bounds via ctx; post-commit: the content clock governs)
	watch := time.NewTimer(w.cfg.IdleTimeout)
	defer watch.Stop()
	contentTick := make(chan struct{}, 1)
	go func() {
		for range contentTick {
			if !watch.Stop() {
				select {
				case <-watch.C:
				default:
				}
			}
			watch.Reset(w.cfg.IdleTimeout)
		}
	}()

	deadline := time.After(w.cfg.HardCeiling)
	errCh := make(chan error, 1)
	sawTerminal := false
	go func() {
		err := parseSSE(rdr, func(ev SSEEvent) error {
			select {
			case <-deadline:
				return errf("hard ceiling exceeded")
			default:
			}
			if ev.Done {
				sawTerminal = true
				return emit(ev) // terminal: relay as-is
			}
			_, finish, _ := contentOf([]byte(ev.Data))
			if finish != "" {
				sawTerminal = true // provider terminal frame ([DONE] may follow)
			}
			text, _, ok := contentOf([]byte(ev.Data))
			if !ok || text == "" {
				// role-only/ping/terminal/tool-call frames relay without committing
				return emit(ev)
			}
			// content-bearing: COMMIT
			mu.Lock()
			*committed = true
			mu.Unlock()
			contentTick <- struct{}{} // reset the idle clock
			*lastContent = time.Now()
			return emit(ev)
		})
		if err == nil && !sawTerminal {
			// EOF without [DONE] or a finish frame: the provider died
			// mid-stream. The parser refuses to lie; the walk refuses to
			// call truncation success.
			err = errf("stream truncated: EOF without terminal frame")
		}
		errCh <- err
	}()

	select {
	case err := <-errCh:
		close(contentTick)
		if err != nil {
			return err
		}
		return nil
	case <-watch.C:
		close(contentTick)
		return errf("idle watchdog fired: no content for %v", w.cfg.IdleTimeout)
	case <-ctx.Done():
		close(contentTick)
		return ctx.Err()
	}
}

func (w *Walk) recordFailure(sc health.Scope, res *StartResult, err error, ctx context.Context) {
	var status int
	var body []byte
	var headers http.Header
	if res != nil {
		status = res.Status
		headers = res.Headers
	}
	if err == nil && res != nil && res.Resp != nil && res.Resp.Body != nil {
		body, _ = readAllLimit(res.Resp.Body, 64*1024)
	}
	w.pools.ReportOutcome(sc, false, 0)
	w.applyClassification(sc, status, body, headers)
}

func (w *Walk) recordStreamFailure(sc health.Scope, streamErr error) {
	w.pools.ReportOutcome(sc, false, 0)
	// stream failures pre-commit are usually connection resets or stalls:
	// a heuristic circuit cooldown, not a quota state
	w.machine.Set(sc, health.Circuit, 90*time.Second, health.Heuristic,
		"pre-commit stream failure: "+streamErr.Error())
}

// applyClassification dispatches a failed response into the health
// machine's states and the ledger's learned ceilings.
func (w *Walk) applyClassification(sc health.Scope, status int, body []byte, headers http.Header) {
	class := health.Dispatch(sc.Provider, status, body, headers)
	hints := health.ParseCeilings(sc.Provider, body, headers)
	if len(hints) > 0 {
		w.led.LearnFromResponse(sc, hints)
	}
	switch class.Kind {
	case health.Retryable:
		w.machine.Set(sc, health.RateLimit, 90*time.Second, health.Heuristic, class.Details)
	case health.KeyFatal:
		w.machine.Set(sc, health.Terminal, 24*time.Hour, health.Heuristic,
			class.Details+" (key-fatal: mark key invalid)")
	case health.ModelFatal:
		w.machine.Set(sc, health.Terminal, 24*time.Hour, health.Heuristic,
			class.Details+" (model-fatal: retire mapping)")
	case health.OverloadQuota:
		// authoritative if a reset was stated, else heuristic escalation
		ttl := time.Until(resetFromHints(hints))
		if ttl <= 0 {
			ttl = 10 * time.Minute
		}
		prov := health.Authoritative
		if resetFromHints(hints).IsZero() {
			prov = health.Heuristic
			ttl = 10 * time.Minute
		}
		w.machine.Set(sc, health.Quota, ttl, prov, class.Details)
	case health.RateLimitHit:
		ttl := 90 * time.Second
		if ra := retryAfter(headers); ra > 0 {
			ttl = ra
		}
		prov := health.Heuristic
		if ra := retryAfter(headers); ra > 0 {
			prov = health.Authoritative
		}
		w.machine.Set(sc, health.RateLimit, ttl, prov, class.Details)
	case health.UnknownRateLimit:
		w.machine.Set(sc, health.RateLimit, 90*time.Second, health.Heuristic, class.Details)
	}
}

// resetFromHints extracts an authoritative reset timestamp from parsed
// hints (unix seconds in Value).
func resetFromHints(hints []health.CeilingHint) time.Time {
	for _, h := range hints {
		if h.Dimension == "reset_at" && h.Value > 0 {
			return time.Unix(int64(h.Value), 0)
		}
	}
	return time.Time{}
}

func retryAfter(headers http.Header) time.Duration {
	if headers == nil {
		return 0
	}
	v := headers.Get("Retry-After")
	if v == "" {
		return 0
	}
	var secs int
	if _, err := fmt.Sscanf(v, "%d", &secs); err == nil && secs > 0 {
		return time.Duration(secs) * time.Second
	}
	return 0
}

func committedVal(b *bool, mu *sync.Mutex) bool {
	mu.Lock()
	defer mu.Unlock()
	return *b
}
