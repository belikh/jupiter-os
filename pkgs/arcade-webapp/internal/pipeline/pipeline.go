// Package pipeline holds the ONE heavy-job lock the arcade webapp's
// runners share (ADV-P5-03): igir verify batches and Skyscraper scrape
// batches each serialized only themselves, so a verify and a scrape could
// overlap — two CPU/IO-heavy jobs on europa's 2-core box, both writing
// into the same games trees (verify promotes while scrape composes
// metadata next to those ROMs). The mutex is constructed once in
// cmd/arcade-webapp/main.go and handed to both runners; each TryAcquire
// failure maps to that runner's existing ErrBusy sentinel, so HTTP
// surfacing (409 conflict / swallowed-in-goroutine) is unchanged.
//
// It is deliberately NOT a full lock around the whole pipeline: scans are
// read-only walks and stay outside; the two heavy exec-driven jobs are
// what never overlap.
package pipeline

import "sync"

// Mutex is a try-lock wrapper over sync.Mutex: callers claim the slot
// non-blockingly and translate failure to their own ErrBusy.
type Mutex struct {
	mu sync.Mutex
}

// TryAcquire claims the pipeline slot without blocking. False = another
// heavy job (verify or scrape) currently holds it.
func (m *Mutex) TryAcquire() bool {
	return m.mu.TryLock()
}

// Release frees a slot claimed by TryAcquire. Call only after a
// successful TryAcquire (exactly-once, like sync.Mutex.Unlock).
func (m *Mutex) Release() {
	m.mu.Unlock()
}
