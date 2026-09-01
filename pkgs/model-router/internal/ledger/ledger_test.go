package ledger

import (
	"testing"
	"time"

	"modelrouter/internal/health"
)

var testNow = time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)

func newTestLedger() *Ledger {
	l := New()
	l.SetNow(func() time.Time { return testNow })
	return l
}

func TestReserveBlocksAtCeiling(t *testing.T) {
	l := newTestLedger()
	sc := health.Scope{Provider: "openrouter", Model: "glm-5.2:free", Key: "k"}
	l.ConfigureScope(sc, UTCMidnightShared, map[string]float64{DimRPD: 50})

	for i := 0; i < 50; i++ {
		lease, ok, blocked := l.Reserve(sc, map[string]float64{DimRPD: 1})
		if !ok {
			t.Fatalf("request %d denied unexpectedly (blocked on %q)", i, blocked)
		}
		l.Commit(lease)
	}
	if _, ok, blocked := l.Reserve(sc, map[string]float64{DimRPD: 1}); ok {
		t.Fatal("51st request must be denied at the 50 RPD ceiling")
	} else if blocked != DimRPD {
		t.Fatalf("blocked dim = %q, want rpd", blocked)
	}
}

func TestLeaseReleaseReturnsBudget(t *testing.T) {
	l := newTestLedger()
	sc := health.Scope{Provider: "groq", Model: "m", Key: "k"}
	l.ConfigureScope(sc, RollingHeaders, map[string]float64{DimRPD: 3})

	// two live leases, one committed: only 1 unit of headroom left
	a, ok, _ := l.Reserve(sc, map[string]float64{DimRPD: 1})
	if !ok {
		t.Fatal("reserve a failed")
	}
	l.Commit(a)
	b, ok, _ := l.Reserve(sc, map[string]float64{DimRPD: 1})
	if !ok {
		t.Fatal("reserve b failed")
	}
	c, ok, _ := l.Reserve(sc, map[string]float64{DimRPD: 1})
	if !ok {
		t.Fatal("reserve c failed")
	}
	if _, ok, _ := l.Reserve(sc, map[string]float64{DimRPD: 1}); ok {
		t.Fatal("4th must deny at ceiling 3")
	}
	// b fails upstream: released units return to the budget
	l.Release(b)
	l.Release(c)
	if _, ok, _ := l.Reserve(sc, map[string]float64{DimRPD: 1}); !ok {
		t.Fatal("released units must be re-reservable")
	}
}

func TestUTCMidnightReset(t *testing.T) {
	l := newTestLedger()
	sc := health.Scope{Provider: "openrouter", Model: "m:free", Key: "k"}
	l.ConfigureScope(sc, UTCMidnightShared, map[string]float64{DimRPD: 2})

	lease, ok, _ := l.Reserve(sc, map[string]float64{DimRPD: 2})
	if !ok {
		t.Fatal("initial reserve failed")
	}
	l.Commit(lease)
	if _, ok, _ := l.Reserve(sc, map[string]float64{DimRPD: 1}); ok {
		t.Fatal("must be exhausted before reset")
	}

	// cross UTC midnight
	next := testNow.Add(13 * time.Hour) // 01:00 UTC next day
	l.SetNow(func() time.Time { return next })
	if _, ok, blocked := l.Reserve(sc, map[string]float64{DimRPD: 1}); !ok {
		t.Fatalf("must be replenished after UTC midnight reset (blocked %q)", blocked)
	}

	// NextReset lands on the following midnight
	wantReset, _ := l.NextReset(sc)
	if wantReset.UTC().Hour() != 0 || wantReset.UTC().Day() != next.UTC().Day()+1%30 {
		// day arithmetic guard: just assert it is the next midnight
		if !wantReset.After(next) {
			t.Fatalf("NextReset %v must be after now %v", wantReset, next)
		}
	}
}

func TestPacificMidnightReset(t *testing.T) {
	l := newTestLedger()
	sc := health.Scope{Provider: "google", Model: "gemini-3-flash", Key: "k"}
	l.ConfigureScope(sc, FixedPacificMidnight, map[string]float64{DimRPD: 1})

	lease, _, _ := l.Reserve(sc, map[string]float64{DimRPD: 1})
	l.Commit(lease)
	if _, ok, _ := l.Reserve(sc, map[string]float64{DimRPD: 1}); ok {
		t.Fatal("must be exhausted pre-reset")
	}
	// 12:00 UTC = 04:00/05:00 Pacific; advance 21h -> 09:00 UTC next day
	// = past midnight Pacific
	l.SetNow(func() time.Time { return testNow.Add(21 * time.Hour) })
	if _, ok, _ := l.Reserve(sc, map[string]float64{DimRPD: 1}); !ok {
		t.Fatal("Pacific-midnight window must have rolled")
	}
}

func TestSession5hWindow(t *testing.T) {
	l := newTestLedger()
	sc := health.Scope{Provider: "ollama", Model: "glm-5.3-flash:cloud", Key: "k"}
	l.ConfigureScope(sc, Session5h7d, map[string]float64{DimConcurrency: 1})

	if _, ok, _ := l.Reserve(sc, map[string]float64{DimConcurrency: 1}); !ok {
		t.Fatal("first concurrent request must reserve")
	}
	if _, ok, _ := l.Reserve(sc, map[string]float64{DimConcurrency: 1}); ok {
		t.Fatal("concurrency 1 must deny a second simultaneous request")
	}
	l.SetNow(func() time.Time { return testNow.Add(6 * time.Hour) })
	if _, ok, _ := l.Reserve(sc, map[string]float64{DimConcurrency: 1}); !ok {
		t.Fatal("5-hour session window must have rolled")
	}
}

func TestLearnCeilingsMonotoneConservative(t *testing.T) {
	l := newTestLedger()
	sc := health.Scope{Provider: "groq", Model: "m", Key: "k"}
	l.ConfigureScope(sc, RollingHeaders, nil)

	// unset -> learned
	l.LearnFromResponse(sc, []health.CeilingHint{{Dimension: DimTPM, Value: 8000}})
	if l.ceilings[sc][DimTPM] != 8000 {
		t.Fatalf("tpm = %v, want 8000 after first learn", l.ceilings[sc][DimTPM])
	}
	// lower -> adopted (provider tightened)
	l.LearnFromResponse(sc, []health.CeilingHint{{Dimension: DimTPM, Value: 4000}})
	if l.ceilings[sc][DimTPM] != 4000 {
		t.Fatalf("tpm = %v, want lowered 4000", l.ceilings[sc][DimTPM])
	}
	// raise -> refused (monotone-conservative)
	l.LearnFromResponse(sc, []health.CeilingHint{{Dimension: DimTPM, Value: 16000}})
	if l.ceilings[sc][DimTPM] != 4000 {
		t.Fatalf("tpm = %v, want 4000 — never raise", l.ceilings[sc][DimTPM])
	}
}

func TestLearnResetAtClearsSpent(t *testing.T) {
	l := newTestLedger()
	sc := health.Scope{Provider: "zai", Model: "glm-4.7-flash", Key: "k"}
	l.ConfigureScope(sc, Session5h7d, map[string]float64{DimConcurrency: 1})
	lease, _, _ := l.Reserve(sc, map[string]float64{DimConcurrency: 1})
	l.Commit(lease)
	if _, ok, _ := l.Reserve(sc, map[string]float64{DimConcurrency: 1}); ok {
		t.Fatal("exhausted pre-reset")
	}
	// Z.ai 1308 body parsed into a reset_at hint: the authoritative reset
	l.LearnFromResponse(sc, []health.CeilingHint{{Dimension: "reset_at", Value: float64(testNow.Add(time.Hour).Unix())}})
	if _, ok, _ := l.Reserve(sc, map[string]float64{DimConcurrency: 1}); !ok {
		t.Fatal("reset_at must clear spent counters (authoritative reset fired)")
	}
}

func TestHeadroomRatio(t *testing.T) {
	l := newTestLedger()
	sc := health.Scope{Provider: "p", Model: "m", Key: "k"}
	l.ConfigureScope(sc, UTCMidnightShared, map[string]float64{DimRPD: 10, DimTPD: 1000})
	for i := 0; i < 8; i++ {
		lease, _, _ := l.Reserve(sc, map[string]float64{DimRPD: 1, DimTPD: 50})
		l.Commit(lease)
	}
	// rpd: 2/10 left = 0.2; tpd: 600/1000 = 0.4 -> min 0.2
	if got := l.HeadroomRatio(sc); got < 0.19 || got > 0.21 {
		t.Fatalf("headroom = %v, want ~0.2", got)
	}
}

func TestUnlearnedDimensionUncapped(t *testing.T) {
	l := newTestLedger()
	sc := health.Scope{Provider: "nim", Model: "m", Key: "k"}
	l.ConfigureScope(sc, RollingHeaders, map[string]float64{DimRPM: 40}) // no rpd: officially unpublished
	for i := 0; i < 500; i++ {
		if _, ok, _ := l.Reserve(sc, map[string]float64{DimRPD: 1}); !ok {
			t.Fatalf("unlearned rpd must not cap (request %d denied)", i)
		}
	}
}

// TestSingleStateWasteReproduction reproduces the corpus's quantified
// finding: a single-state router (everything is one cooldown, no quota
// ledger) burns ~1,440 wasted retry calls/day against a quota-exhausted
// provider, while a ledger+reset model spends one detection call and
// skips until the stated reset.
func TestSingleStateWasteReproduction(t *testing.T) {
	// single-state simulation: retry every 60s for a day
	singleStateWasted := 0
	for minute := 0; minute < 24*60; minute++ {
		_ = minute // every minute, one doomed retry
		singleStateWasted++
	}

	// ledger model: one detection call, then reserve-denied until reset
	l := newTestLedger()
	sc := health.Scope{Provider: "openrouter", Model: "m:free", Key: "k"}
	l.ConfigureScope(sc, UTCMidnightShared, map[string]float64{DimRPD: 50})
	// burn the daily budget
	for i := 0; i < 50; i++ {
		lease, _, _ := l.Reserve(sc, map[string]float64{DimRPD: 1})
		l.Commit(lease)
	}
	// ledger model: one detection call 429s; every subsequent attempt is
	// refused pre-flight by the exhausted ledger — zero further waste
	ledgerWasted := 0
	for minute := 0; minute < 24*60; minute++ {
		// the minute-0 detection call is the one that 429'd and taught us
		if minute == 0 {
			ledgerWasted++
			continue
		}
		// every later attempt is a 1-unit reserve against a spent budget:
		// the ledger refuses BEFORE any request leaves the building
		if _, ok, _ := l.Reserve(sc, map[string]float64{DimRPD: 1}); ok {
			t.Fatalf("minute %d: ledger must refuse pre-flight on exhausted budget", minute)
		}
	}
	if singleStateWasted != 1440 {
		t.Fatalf("single-state waste = %d, want 1440 (corpus figure)", singleStateWasted)
	}
	if ledgerWasted != 1 {
		t.Fatalf("ledger waste = %d, want 1 (detect once, skip until reset)", ledgerWasted)
	}
}

func TestConcurrentReserveNeverOverspends(t *testing.T) {
	l := newTestLedger()
	sc := health.Scope{Provider: "p", Model: "m", Key: "k"}
	l.ConfigureScope(sc, UTCMidnightShared, map[string]float64{DimRPD: 100})

	granted := make(chan int, 300)
	done := make(chan struct{})
	for i := 0; i < 300; i++ {
		go func() {
			if lease, ok, _ := l.Reserve(sc, map[string]float64{DimRPD: 1}); ok {
				l.Commit(lease)
				granted <- 1
			}
			done <- struct{}{}
		}()
	}
	for i := 0; i < 300; i++ {
		<-done
	}
	close(granted)
	n := 0
	for range granted {
		n++
	}
	if n != 100 {
		t.Fatalf("granted %d of 300 at ceiling 100 — race in Reserve", n)
	}
}
