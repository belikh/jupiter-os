package igir

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/dats"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/pipeline"
)

// lockDAT writes a dat-lock.json entry pinning the CURRENT bytes of
// <datDir>/<sys>.dat (the honest attestation path) or, when tamper is
// true, pins DIFFERENT bytes (an on-disk swap after attestation).
func lockDAT(t *testing.T, datDir, sys string, tamper bool) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(datDir, sys+".dat"))
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256Hex(b)
	if tamper {
		sum = sha256Hex(append(append([]byte{}, b...), 'X'))
	}
	lock := &dats.Lock{Systems: map[string]dats.LockEntry{
		sys: {
			SourceCommit: strings.Repeat("a", 40),
			BytesSHA256:  sum,
			RomCount:     4,
			FetchedAt:    "2026-08-29T00:00:00Z",
		},
	}}
	if err := dats.WriteLock(datDir, lock); err != nil {
		t.Fatal(err)
	}
}

// TestDATLockMismatchRefusesPromotion (remediation W4b acceptance): a
// DAT whose on-disk bytes fail its dat-lock entry is rejected — igir is
// never exec'd, nothing is promoted, the outcome is the distinct
// dat-lock-mismatch label, and the run is an error.
func TestDATLockMismatchRefusesPromotion(t *testing.T) {
	r := newRig(t)
	r.stage("nes", "Starlit Vault (USA).nes")
	r.stageDAT("nes")
	lockDAT(t, r.datDir, "nes", true) // pin NOT the on-disk bytes

	outcomes, err := r.runner.Verify([]string{"nes"})
	if err != nil {
		t.Fatal(err)
	}
	if len(outcomes) != 1 || outcomes[0].Outcome != OutcomeDATLock {
		t.Fatalf("outcome = %+v, want dat-lock-mismatch", outcomes)
	}
	if !strings.Contains(outcomes[0].Err, "dat-lock") {
		t.Errorf("outcome error = %q, want the lock-mismatch detail", outcomes[0].Err)
	}
	// igir was NEVER exec'd (no argv recorded) and nothing was promoted.
	if argv := r.argv(); len(argv) != 0 {
		t.Errorf("igir exec'd despite the lock mismatch: %v", argv)
	}
	if _, err := os.Stat(filepath.Join(r.cartr, "nes")); !os.IsNotExist(err) {
		t.Error("output tree created despite the lock mismatch")
	}
	if vr := r.verifyResult("nes"); vr != nil {
		t.Errorf("verify_result recorded = %+v, want none (promotion refused)", vr)
	}
	// The run closes as an error (batch status reflects the refusal).
	runs, _ := r.st.RecentRuns(5)
	for _, run := range runs {
		if run.Kind == "verify" && run.Status != "error" {
			t.Errorf("verify run status = %s, want error", run.Status)
		}
	}
}

// TestLockedDATVerifiesWhenBytesMatch: a matching lock never blocks the
// normal flow (the gate is pinning, not paranoia).
func TestLockedDATVerifiesWhenBytesMatch(t *testing.T) {
	r := newRig(t)
	r.stage("nes", "Starlit Vault (USA).nes")
	r.stageDAT("nes")
	lockDAT(t, r.datDir, "nes", false) // pin IS the on-disk bytes

	outcomes, err := r.runner.Verify([]string{"nes"})
	if err != nil {
		t.Fatal(err)
	}
	if len(outcomes) != 1 || outcomes[0].Outcome != OutcomeVerified {
		t.Fatalf("outcome = %+v, want verified (lock matches)", outcomes)
	}
}

// TestUncheckedPromoteRechecksInFlight (W4d TOCTOU): a download that
// starts AFTER the batch's first in-flight check must still be refused
// at the immediately-before-copy re-check — the no-DAT promote path is
// exactly as exposed as the igir path.
func TestUncheckedPromoteRechecksInFlight(t *testing.T) {
	r := newRig(t)
	r.stage("nes", "Starlit Vault (USA).nes")
	// No DAT: the unchecked-promote path.

	// Interpose: the FIRST in-flight check (batch entry) sees nothing;
	// right after it, "aria2 starts" (a control file lands).
	orig := hasAria2Control
	hasAria2Control = func(dir string) bool {
		defer func() { hasAria2Control = orig }()
		_ = os.WriteFile(filepath.Join(dir, "inflight.aria2"), nil, 0o644)
		return false
	}
	t.Cleanup(func() { hasAria2Control = orig })

	outcomes, err := r.runner.Verify([]string{"nes"})
	if err != nil {
		t.Fatal(err)
	}
	if len(outcomes) != 1 || outcomes[0].Outcome != OutcomeSkippedDownloading {
		t.Fatalf("outcome = %+v, want skipped-downloading (copy re-check refused the mid-flight download)", outcomes)
	}
	if _, err := os.Stat(filepath.Join(r.cartr, "nes")); !os.IsNotExist(err) {
		t.Error("partial download was promoted unchecked through the TOCTOU window")
	}
}

// TestIgirExecRechecksInFlight (W4d TOCTOU): the same window on the
// DAT'd path — the control file appears after the batch's first check
// but before the mkdir/exec sequence; the immediately-before-exec
// re-check skips the system instead of verifying half-downloaded files.
func TestIgirExecRechecksInFlight(t *testing.T) {
	r := newRig(t)
	r.stage("nes", "Starlit Vault (USA).nes")
	r.stageDAT("nes")

	orig := hasAria2Control
	hasAria2Control = func(dir string) bool {
		defer func() { hasAria2Control = orig }()
		_ = os.WriteFile(filepath.Join(dir, "inflight.aria2"), nil, 0o644)
		return false
	}
	t.Cleanup(func() { hasAria2Control = orig })

	outcomes, err := r.runner.Verify([]string{"nes"})
	if err != nil {
		t.Fatal(err)
	}
	if len(outcomes) != 1 || outcomes[0].Outcome != OutcomeSkippedDownloading {
		t.Fatalf("outcome = %+v, want skipped-downloading (exec re-check refused the mid-flight download)", outcomes)
	}
	if argv := r.argv(); len(argv) != 0 {
		t.Errorf("igir exec'd on a mid-flight download: %v", argv)
	}
}

// TestFailureCounterCountsActualFailures (W4d): the runner's LastError
// used to report the BATCH SIZE as the failure count — a 2-system batch
// with one failure said "2 failed systems". It must say 1.
func TestFailureCounterCountsActualFailures(t *testing.T) {
	r := newRig(t)
	r.stage("nes", "Starlit Vault (USA).nes")
	r.stageDAT("nes")
	r.stage("segacd", "Sega CD Game (USA).cue")
	r.stageDAT("segacd")
	// segacd's igir run exits non-zero (report still written — the
	// exit-1-with-report class); nes succeeds.
	t.Setenv("FAKE_IGIR_FAIL_INPUT", filepath.Join(r.incoming, "segacd"))

	if _, err := r.runner.Verify([]string{"nes", "segacd"}); err != nil {
		t.Fatal(err)
	}
	state := r.runner.State()
	if got, want := state.LastError, "1 failed system(s)"; got != want {
		t.Errorf("LastError = %q, want %q (the ACTUAL failed-system count, never the batch size)", got, want)
	}
}

// TestPostVerifyRescanRunsOutsidePipelineLock (W4d): the rescan is
// kicked AFTER the shared heavy-job slot is released — inside the lock
// it extended every verify's scrape/generate lockout by the whole
// multi-TiB-tree rescan.
func TestPostVerifyRescanRunsOutsidePipelineLock(t *testing.T) {
	r := newRig(t)
	r.stage("nes", "Starlit Vault (USA).nes")
	r.stageDAT("nes")

	mu := &pipeline.Mutex{}
	r.runner.Pipeline = mu

	// The rescan hook TryAcquires the same slot: if the rescan ran while
	// Verify still held the lock, the acquire fails and rescanSeen stays
	// unflagged (this is exactly what the web layer's own handlers do to
	// answer 409s fast).
	rescanSawLockFree := false
	r.runner.rescan = func() error {
		rescanSawLockFree = mu.TryAcquire()
		if rescanSawLockFree {
			mu.Release()
		}
		return nil
	}

	outcomes, err := r.runner.Verify([]string{"nes"})
	if err != nil {
		t.Fatal(err)
	}
	if len(outcomes) != 1 || outcomes[0].Outcome != OutcomeVerified {
		t.Fatalf("outcome = %+v, want verified (fixture sanity)", outcomes)
	}
	if !rescanSawLockFree {
		t.Fatal("post-verify rescan ran with the pipeline lock still held — it must run outside the heavy-job slot")
	}
	// And the slot is free after Verify returns.
	if !mu.TryAcquire() {
		t.Fatal("pipeline lock still held after Verify returned")
	}
	mu.Release()
}

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}
