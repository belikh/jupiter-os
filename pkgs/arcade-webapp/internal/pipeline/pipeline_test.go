package pipeline

import "testing"

// TestMutexTryAcquireRelease pins the try-lock contract the runners rely
// on: first claim wins, a competing claim fails without blocking, and
// Release makes the slot claimable again.
func TestMutexTryAcquireRelease(t *testing.T) {
	var m Mutex

	if !m.TryAcquire() {
		t.Fatal("first TryAcquire = false, want true")
	}
	if m.TryAcquire() {
		t.Fatal("second TryAcquire while held = true, want false (non-blocking)")
	}
	m.Release()
	if !m.TryAcquire() {
		t.Fatal("TryAcquire after Release = false, want true")
	}
	m.Release()
}
