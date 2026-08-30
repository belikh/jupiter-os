package dats

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/fixture"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// stubCommit pins a deterministic fake Fresh1G1R commit SHA (40 hex —
// the shape the resolver demands). Tests NEVER touch GitHub: the
// commit endpoint is a stubbed JSON document, the DAT tree a stubbed
// path hierarchy.
const stubCommit = "0ae05e3e2ab1125af306f5b9a7d90fc546f3c66a"

// stubDats serves a deterministic Fresh1G1R-shaped tree:
// /commit.json -> {"sha": ...} and
// /<commit>/daily-1g1r-dat/McLean/<encoded rel path> -> fixture DAT
// bytes. It records every requested path so the tests assert the exact
// commit-pinned URLs the fetcher builds (the encoding is load-bearing:
// spaces, parens, ampersands).
func stubDats(t *testing.T, hits *[]string) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/commit.json", func(w http.ResponseWriter, r *http.Request) {
		*hits = append(*hits, r.RequestURI)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"sha": "` + stubCommit + `", "commit": {"message": "daily"}}`))
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// RequestURI is the raw wire form — URL.Path comes back
		// DECODED, which would hide an encoding bug.
		*hits = append(*hits, r.RequestURI)
		// Map back to a fixture DAT by collection dir shape only — the
		// stub accepts any <commit>/<subdir>/<coll>/<name>.dat and
		// serves the gb fixture.
		if !strings.HasSuffix(r.URL.Path, ".dat") {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/xml")
		_, _ = w.Write([]byte(fixture.DAT(fixture.Systems()[2]))) // gb
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func openStore(t *testing.T) *store.Store {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "dats.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() }) //nolint:errcheck // test
	if err := st.UpsertSystems([]store.SystemRow{
		{Key: "nes", Collection: "NES", Bucket: "cartridge", SortOrder: 1, Extensions: `["nes"]`},
		{Key: "segacd", Collection: "Sega CD", Bucket: "optical", SortOrder: 2, Extensions: `["cue"]`},
		{Key: "wiiu", Collection: "Wii U", Bucket: "modern", SortOrder: 3, Extensions: `["wua"]`},
	}); err != nil {
		t.Fatal(err)
	}
	return st
}

// newFetcher wires a Fetcher against the stub host with the commit
// endpoint stubbed too (never the real GitHub API).
func newFetcher(t *testing.T, st *store.Store, srv *httptest.Server, dir string) *Fetcher {
	t.Helper()
	return &Fetcher{
		BaseURL:   srv.URL,
		CommitURL: srv.URL + "/commit.json",
		Dir:       dir,
		St:        st,
	}
}

// TestEncodePathMatchesJqURI pins the script's jq @uri semantics on the
// gnarliest real basename: unreserved bytes and '/' pass through, spaces
// and parens (Fresh1G1R filenames are full of both) are hex-encoded.
func TestEncodePathMatchesJqURI(t *testing.T) {
	got := encodePath("no-intro/Nintendo - Nintendo Entertainment System (Headerless) (No-Intro - Fresh1G1R - McLean).dat")
	want := "no-intro/Nintendo%20-%20Nintendo%20Entertainment%20System%20%28Headerless%29%20%28No-Intro%20-%20Fresh1G1R%20-%20McLean%29.dat"
	if got != want {
		t.Errorf("encodePath =\n  %s\nwant\n  %s", got, want)
	}
	// Ampersand (Sega CD DAT) and every unreserved char survive.
	if got, want := encodePath("redump/Sega - Mega CD & Sega CD (Redump - Fresh1G1R - McLean).dat"),
		"redump/Sega%20-%20Mega%20CD%20%26%20Sega%20CD%20%28Redump%20-%20Fresh1G1R%20-%20McLean%29.dat"; got != want {
		t.Errorf("encodePath (ampersand) = %s, want %s", got, want)
	}
	if got, want := encodePath("no-intro/ABC-xyz_09~.dat"), "no-intro/ABC-xyz_09~.dat"; got != want {
		t.Errorf("encodePath (unreserved) = %s, want %s", got, want)
	}
}

// TestMcLeanTableCoversCatalogueBuckets pins the load-bearing mapping
// facts the script documents: every mapped value names a real collection
// prefix, and the deliberately-unmapped systems stay unmapped.
func TestMcLeanTableCoversCatalogueBuckets(t *testing.T) {
	for sys, rel := range McLeanDATs {
		if !strings.HasPrefix(rel, "no-intro/") && !strings.HasPrefix(rel, "redump/") {
			t.Errorf("%s: %q does not name a no-intro/ or redump/ collection", sys, rel)
		}
		if !strings.HasSuffix(rel, ".dat") {
			t.Errorf("%s: %q is not a .dat basename", sys, rel)
		}
	}
	for _, sys := range []string{"wiiu", "pcfx", "zxspectrum"} {
		if _, ok := McLeanDATs[sys]; ok {
			t.Errorf("%s: intentionally-unmapped system must stay out of McLeanDATs", sys)
		}
	}
	if len(McLeanDATs) != 58 {
		t.Errorf("McLeanDATs has %d entries, want 58 (fetch-mclean-1g1r-dats.sh's table)", len(McLeanDATs))
	}
}

func TestRefreshWritesDATsAndRecordsRun(t *testing.T) {
	st := openStore(t)
	var hits []string
	srv := stubDats(t, &hits)
	dir := filepath.Join(t.TempDir(), "dats")

	f := newFetcher(t, st, srv, dir)
	res := f.Refresh(context.Background(), mustSystems(t, st))

	if res.Systems != 3 || res.Fetched != 2 || res.Unmapped != 1 {
		t.Errorf("Refresh result = %+v, want 3 systems / 2 fetched / 1 unmapped (wiiu)", res)
	}
	if len(res.Warnings) != 0 {
		t.Errorf("unexpected warnings: %v", res.Warnings)
	}
	// Both mapped systems landed under the per-system naming contract.
	for _, sys := range []string{"nes", "segacd"} {
		if _, err := os.Stat(filepath.Join(dir, sys+".dat")); err != nil {
			t.Errorf("%s.dat not written: %v", sys, err)
		}
	}
	// The URLs the stub saw are exactly BaseURL + <pinned commit> +
	// subdir + encoded collection paths — COMMIT-PINNED, never a
	// mutable branch ref (W4b).
	wantPaths := map[string]bool{
		"/" + stubCommit + "/daily-1g1r-dat/McLean/no-intro/Nintendo%20-%20Nintendo%20Entertainment%20System%20%28Headerless%29%20%28No-Intro%20-%20Fresh1G1R%20-%20McLean%29.dat": true,
		"/" + stubCommit + "/daily-1g1r-dat/McLean/redump/Sega%20-%20Mega%20CD%20%26%20Sega%20CD%20%28Redump%20-%20Fresh1G1R%20-%20McLean%29.dat":                                           true,
	}
	if len(hits) != 3 { // commit.json + 2 DATs
		t.Fatalf("stub saw %d requests (%v), want 3", len(hits), hits)
	}
	sawCommitResolve := false
	for _, h := range hits {
		if h == "/commit.json" {
			sawCommitResolve = true
			continue
		}
		if !wantPaths[h] {
			t.Errorf("unexpected fetch URL: %s", h)
		}
	}
	if !sawCommitResolve {
		t.Errorf("commit endpoint never queried — fetch was not commit-pinned")
	}
	// dat_info refreshed immediately (the currency card updates without a
	// rescan) — the stub serves the gb fixture DAT (date 2026-08-21).
	info, err := st.DATInfo("nes")
	if err != nil || info == nil {
		t.Fatalf("DATInfo(nes) after refresh = %v, %v", info, err)
	}
	if info.Date != "2026-08-21" || info.RomCount != 4 {
		t.Errorf("DATInfo(nes) = %+v, want gb fixture header (4 roms, 2026-08-21)", info)
	}
	// The batch is recorded as a dat-fetch run.
	run, err := st.LastRun()
	if err != nil || run == nil {
		t.Fatalf("LastRun = %v, %v", run, err)
	}
	if run.Kind != "dat-fetch" || run.Status != "ok" {
		t.Errorf("run = %s/%s, want dat-fetch/ok", run.Kind, run.Status)
	}
}

// TestRefreshWritesLockAndLedger (W4b): one accepted generation writes
// the content-addressed lock AND appends exactly one dat_versions row;
// a second refresh at the SAME commit with the SAME bytes appends
// NOTHING (one commit per accepted generation).
func TestRefreshWritesLockAndLedger(t *testing.T) {
	st := openStore(t)
	var hits []string
	srv := stubDats(t, &hits)
	dir := filepath.Join(t.TempDir(), "dats")
	f := newFetcher(t, st, srv, dir)

	f.Refresh(context.Background(), mustSystems(t, st))

	lock, err := ReadLock(dir)
	if err != nil {
		t.Fatalf("ReadLock: %v", err)
	}
	entry, ok := lock.Systems["nes"]
	if !ok {
		t.Fatalf("lock has no nes entry after refresh: %+v", lock.Systems)
	}
	if entry.SourceCommit != stubCommit || len(entry.BytesSHA256) != 64 || entry.RomCount != 4 || entry.FetchedAt == "" {
		t.Errorf("nes lock entry = %+v, want stub commit + sha256 + 4 roms + timestamp", entry)
	}
	// The locked hash matches the on-disk file — CheckLock must pass.
	if err := CheckLock(dir, "nes"); err != nil {
		t.Errorf("CheckLock(nes) after refresh = %v, want nil", err)
	}

	v1, err := st.DATVersions("nes", 0)
	if err != nil {
		t.Fatalf("DATVersions: %v", err)
	}
	if len(v1) != 1 {
		t.Fatalf("dat_versions rows for nes = %d, want 1", len(v1))
	}
	if v1[0].SourceCommit != stubCommit || v1[0].BytesSHA256 != entry.BytesSHA256 || v1[0].RomCount != 4 {
		t.Errorf("dat_versions row = %+v, want the locked generation", v1[0])
	}

	// Idempotent re-fetch at the same commit + same bytes: no new rows.
	res := f.Refresh(context.Background(), mustSystems(t, st))
	if len(res.Warnings) != 0 {
		t.Errorf("second refresh warnings: %v", res.Warnings)
	}
	v2, _ := st.DATVersions("nes", 0)
	if len(v2) != 1 {
		t.Errorf("dat_versions rows after idempotent re-fetch = %d, want 1 (one row per accepted generation)", len(v2))
	}
}

// TestFetchRefusesHashMismatch (W4b acceptance): the same commit serving
// DIFFERENT bytes than the lock attested is refused — the file is never
// installed, the lock and ledger stay at the last good generation.
func TestFetchRefusesHashMismatch(t *testing.T) {
	st := openStore(t)
	srv := stubDats(t, &[]string{})
	dir := filepath.Join(t.TempDir(), "dats")
	f := newFetcher(t, st, srv, dir)

	if res := f.Refresh(context.Background(), mustSystems(t, st)); len(res.Warnings) != 0 {
		t.Fatalf("first refresh warnings: %v", res.Warnings)
	}
	lock, _ := ReadLock(dir)
	good := lock.Systems["nes"]
	goodBytes, _ := os.ReadFile(filepath.Join(dir, "nes.dat"))

	// Second server: same commit, MUTATED bytes (the torn-download /
	// poisoned-cache class).
	var hits2 []string
	srv2 := stubDats(t, &hits2)
	srv2.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/commit.json" {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"sha": "` + stubCommit + `"}`))
			return
		}
		if strings.HasSuffix(r.URL.Path, ".dat") {
			_, _ = w.Write(append(append([]byte{}, goodBytes...), []byte("MUTATED")...))
			return
		}
		http.NotFound(w, r)
	})
	f2 := newFetcher(t, st, srv2, dir)
	res := f2.Refresh(context.Background(), mustSystems(t, st))

	found := false
	for _, w := range res.Warnings {
		if strings.Contains(w, "fails its dat-lock entry") {
			found = true
		}
	}
	if !found {
		t.Fatalf("no lock-mismatch warning for nes: %v", res.Warnings)
	}
	// The on-disk file is still the GOOD generation.
	got, _ := os.ReadFile(filepath.Join(dir, "nes.dat"))
	if string(got) != string(goodBytes) {
		t.Error("mutated bytes were installed over the locked generation — refusal failed")
	}
	lock2, _ := ReadLock(dir)
	if lock2.Systems["nes"] != good {
		t.Errorf("lock entry moved: %+v -> %+v", good, lock2.Systems["nes"])
	}
	v, _ := st.DATVersions("nes", 0)
	if len(v) != 1 {
		t.Errorf("dat_versions rows = %d, want 1 (mutated generation must not append)", len(v))
	}
}

// TestCheckLockDetectsOnDiskTamper (W4b acceptance): a DAT whose bytes
// don't match its lock entry is rejected — this is the gate the igir
// runner consults immediately before exec.
func TestCheckLockDetectsOnDiskTamper(t *testing.T) {
	st := openStore(t)
	srv := stubDats(t, &[]string{})
	dir := filepath.Join(t.TempDir(), "dats")
	f := newFetcher(t, st, srv, dir)
	f.Refresh(context.Background(), mustSystems(t, st))

	path := filepath.Join(dir, "nes.dat")
	if err := os.WriteFile(path, []byte("tampered bytes"), 0o644); err != nil {
		t.Fatal(err)
	}
	err := CheckLock(dir, "nes")
	if err == nil {
		t.Fatal("CheckLock after on-disk tamper = nil, want LockMismatch")
	}
	var mm *LockMismatch
	if !errors.As(err, &mm) {
		t.Fatalf("CheckLock error = %T (%v), want *LockMismatch", err, err)
	}
	if mm.SystemKey != "nes" || mm.OnDiskSHA == mm.Entry.BytesSHA256 {
		t.Errorf("mismatch detail = %+v", mm)
	}
	// Unlocked system (no entry): nil — bootstrap proceeds.
	if err := CheckLock(dir, "wiiu"); err != nil {
		t.Errorf("CheckLock(unlocked wiiu) = %v, want nil", err)
	}
}

// TestCommitResolveFailureFallsBackToLockPin: a dead commit endpoint
// degrades the refresh to the lock's pinned generation instead of
// killing DAT currency outright.
func TestCommitResolveFailureFallsBackToLockPin(t *testing.T) {
	st := openStore(t)
	srv := stubDats(t, &[]string{})
	dir := filepath.Join(t.TempDir(), "dats")
	f := newFetcher(t, st, srv, dir)
	f.Refresh(context.Background(), mustSystems(t, st))

	// Commit endpoint dead, DAT tree alive at the pinned commit path.
	var hits []string
	srv2 := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits = append(hits, r.URL.Path)
		if strings.HasSuffix(r.URL.Path, ".dat") {
			_, _ = w.Write([]byte(fixture.DAT(fixture.Systems()[2])))
			return
		}
		http.NotFound(w, r)
	}))
	t.Cleanup(srv2.Close)
	dead := &Fetcher{BaseURL: srv2.URL, CommitURL: srv2.URL + "/commit.json", Dir: dir, St: st}
	res := dead.Refresh(context.Background(), mustSystems(t, st))
	if len(res.Warnings) != 0 {
		t.Fatalf("fallback refresh warnings: %v", res.Warnings)
	}
	if res.Fetched != 2 {
		t.Errorf("Fetched via lock pin = %d, want 2", res.Fetched)
	}
	for _, h := range hits {
		if h == "/commit.json" {
			continue // the (failed) resolve attempt itself
		}
		if !strings.HasPrefix(h, "/"+stubCommit+"/") {
			t.Errorf("fallback fetch not at the lock's pinned commit: %s", h)
		}
	}
}

// TestLivenessAlarmOnAsymmetry (W4b): no-intro frozen >21d while redump
// fetched <14d ago fires the alarm; symmetric ages and missing history
// do not.
func TestLivenessAlarmOnAsymmetry(t *testing.T) {
	st := openStore(t)
	now := time.Date(2026, 9, 29, 12, 0, 0, 0, time.UTC)

	// No history at all: no alarm.
	if frozen, _ := Liveness(st, now); frozen {
		t.Error("alarm fired with no dat_versions history")
	}

	// Asymmetry: nes (no-intro) fetched 30d ago, segacd (redump) 2d ago.
	old := now.AddDate(0, 0, -30).UTC().Format(time.RFC3339)
	fresh := now.AddDate(0, 0, -2).UTC().Format(time.RFC3339)
	if err := st.AppendDATVersion(store.DATVersion{SystemKey: "nes", SourceCommit: stubCommit, BytesSHA256: strings.Repeat("a", 64), FetchedAt: old}); err != nil {
		t.Fatal(err)
	}
	if err := st.AppendDATVersion(store.DATVersion{SystemKey: "segacd", SourceCommit: stubCommit, BytesSHA256: strings.Repeat("b", 64), FetchedAt: fresh}); err != nil {
		t.Fatal(err)
	}
	frozen, detail := Liveness(st, now)
	if !frozen || !strings.Contains(detail, "no-intro") || !strings.Contains(detail, "broken leg") {
		t.Errorf("alarm = (%v, %q), want frozen asymmetry detail", frozen, detail)
	}

	// Symmetric freshness: newest no-intro row 5d old — no alarm.
	if err := st.AppendDATVersion(store.DATVersion{SystemKey: "nes", SourceCommit: stubCommit, BytesSHA256: strings.Repeat("c", 64), FetchedAt: fresh}); err != nil {
		t.Fatal(err)
	}
	if frozen, detail := Liveness(st, now); frozen {
		t.Errorf("alarm fired on symmetric freshness: %q", detail)
	}
}

func TestRefreshPerSystemFailuresNeverAbortBatch(t *testing.T) {
	st := openStore(t)
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/commit.json" {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"sha": "` + stubCommit + `"}`))
			return
		}
		if atomic.AddInt32(&calls, 2) == 2 { // first DAT request (nes) fails
			w.WriteHeader(http.StatusNotFound)
			return
		}
		_, _ = w.Write([]byte(fixture.DAT(fixture.Systems()[2])))
	}))
	t.Cleanup(srv.Close)

	f := &Fetcher{BaseURL: srv.URL, CommitURL: srv.URL + "/commit.json", Dir: filepath.Join(t.TempDir(), "dats"), St: st}
	res := f.Refresh(context.Background(), mustSystems(t, st))

	if res.Fetched != 1 {
		t.Errorf("Fetched = %d, want 1 (segacd succeeded past nes's 404)", res.Fetched)
	}
	if len(res.Warnings) != 1 || !strings.Contains(res.Warnings[0], "nes: HTTP 404") {
		t.Errorf("Warnings = %v, want nes 404 warning", res.Warnings)
	}
	// A failed system leaves no partial file behind (temp + rename).
	if _, err := os.Stat(filepath.Join(f.Dir, "nes.dat")); !os.IsNotExist(err) {
		t.Errorf("nes.dat exists after a failed fetch (%v) — torn writes must not land", err)
	}
}

func TestRefreshSystemUnmappedAndUnreachable(t *testing.T) {
	st := openStore(t)
	var hits []string
	srv := stubDats(t, &hits)
	f := newFetcher(t, st, srv, filepath.Join(t.TempDir(), "dats"))
	systems := mustSystems(t, st)

	// wiiu: deliberately unmapped — a distinct, checkable error.
	if err := f.RefreshSystem(context.Background(), systems[2]); err == nil || !strings.Contains(err.Error(), "no McLean DAT mapping") {
		t.Errorf("RefreshSystem(wiiu) err = %v, want ErrNotMapped", err)
	}
	// Unreachable host: transport error surfaces, run recorded as error.
	dead := &Fetcher{BaseURL: "http://127.0.0.1:1", CommitURL: "http://127.0.0.1:1/commit.json", Dir: filepath.Join(t.TempDir(), "dats"), St: st}
	if err := dead.RefreshSystem(context.Background(), systems[0]); err == nil {
		t.Error("RefreshSystem against a dead host should fail")
	}
	run, _ := st.LastRun()
	if run == nil || run.Kind != "dat-fetch" || run.Status != "error" {
		t.Errorf("failed refresh run = %+v, want dat-fetch/error", run)
	}
	// Happy single-system path still writes + records ok.
	if err := f.RefreshSystem(context.Background(), systems[0]); err != nil {
		t.Fatalf("RefreshSystem(nes): %v", err)
	}
	if _, err := os.Stat(filepath.Join(f.Dir, "nes.dat")); err != nil {
		t.Errorf("nes.dat not written: %v", err)
	}
	run, _ = st.LastRun()
	if run == nil || run.Status != "ok" {
		t.Errorf("single-system run = %+v, want ok", run)
	}
}

func TestURLFor(t *testing.T) {
	u := URLFor("http://stub", "nes")
	if !strings.HasPrefix(u, "http://stub/<commit>/daily-1g1r-dat/McLean/no-intro/") ||
		!strings.HasSuffix(u, ".dat") || strings.ContainsAny(u, " ()") {
		t.Errorf("URLFor(nes) = %q, want commit-pinned encoded no-intro URL", u)
	}
	if u := URLFor("http://stub", "wiiu"); u != "" {
		t.Errorf("URLFor(wiiu) = %q, want empty (unmapped)", u)
	}
}

// TestLockRoundTrip pins the lock document's shape on disk (the
// content-addressed contract other tooling may read).
func TestLockRoundTrip(t *testing.T) {
	dir := t.TempDir()
	l := &Lock{Systems: map[string]LockEntry{
		"nes": {SourceCommit: stubCommit, BytesSHA256: strings.Repeat("a", 64), RomCount: 4, FetchedAt: "2026-08-29T00:00:00Z"},
	}}
	if err := WriteLock(dir, l); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(dir, LockFileName))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{`"systems"`, `"source_commit": "` + stubCommit + `"`, `"bytes_sha256"`, `"rom_count": 4`, `"fetched_at"`} {
		if !strings.Contains(string(b), want) {
			t.Errorf("lock document missing %s:\n%s", want, b)
		}
	}
	got, err := ReadLock(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got.Systems["nes"] != l.Systems["nes"] {
		t.Errorf("round trip = %+v, want %+v", got.Systems["nes"], l.Systems["nes"])
	}
	// Missing file = empty lock (bootstrap), never an error.
	empty, err := ReadLock(t.TempDir())
	if err != nil || empty == nil || len(empty.Systems) != 0 {
		t.Errorf("ReadLock(missing) = %v, %v; want empty lock, nil", empty, err)
	}
}

// committedDats is the repo's self-authored fixture corpus (testdata/dats
// — see internal/fixture), with its committed dat-lock.json (W4b item 7):
// the lock pins the corpus DATs' actual bytes so the supply-chain gate is
// exercised against the REAL committed shape, not only stub-server bytes.
const committedDats = "../../testdata/dats"

// corpusLockCommit is the invented 40-hex commit the corpus lock pins —
// the fixture corpus is self-authored (never fetched from Fresh1G1R), so
// the commit is a deliberately obvious sentinel, not a real SHA.
const corpusLockCommit = "0000000000000000000000000000000000000001"

// TestCommittedCorpusLockMatchesBytes (W4b item 7): the committed
// dat-lock.json fixture must match the committed DAT bytes EXACTLY —
// CheckLock passes for every pinned system, and a byte-tampered corpus
// DAT is refused with *LockMismatch. Re-bootstrapping the DAT corpus
// (fixture domain bump, game-list change) without re-writing the lock
// fails here, closing the "regenerated DATs, stale lock" drift class the
// generator's own equivalence test cannot see.
func TestCommittedCorpusLockMatchesBytes(t *testing.T) {
	// Operate on a COPY: the tamper half must never touch the committed
	// corpus.
	dir := t.TempDir()
	for _, sys := range []string{"nes", "snes", "gb"} {
		b, err := os.ReadFile(filepath.Join(committedDats, sys+".dat"))
		if err != nil {
			t.Fatalf("read committed %s.dat: %v", sys, err)
		}
		if err := os.WriteFile(filepath.Join(dir, sys+".dat"), b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	b, err := os.ReadFile(filepath.Join(committedDats, LockFileName))
	if err != nil {
		t.Fatalf("read committed %s: %v (the W4b item-7 fixture is missing)", LockFileName, err)
	}
	if err := os.WriteFile(filepath.Join(dir, LockFileName), b, 0o644); err != nil {
		t.Fatal(err)
	}

	lock, err := ReadLock(dir)
	if err != nil {
		t.Fatalf("ReadLock(committed fixture): %v", err)
	}
	if len(lock.Systems) != 3 {
		t.Fatalf("committed lock pins %d systems, want 3 (nes/snes/gb — mclean-shape.dat is a parse fixture, not corpus)", len(lock.Systems))
	}
	for sys, entry := range lock.Systems {
		if entry.SourceCommit != corpusLockCommit {
			t.Errorf("%s: fixture lock pins commit %q, want the corpus sentinel %q", sys, entry.SourceCommit, corpusLockCommit)
		}
		if len(entry.BytesSHA256) != 64 {
			t.Errorf("%s: fixture lock sha256 %q is not 64 hex chars", sys, entry.BytesSHA256)
		}
		if err := CheckLock(dir, sys); err != nil {
			t.Errorf("CheckLock(%s) against the committed corpus = %v, want nil (fixture lock is stale — re-bootstrap testdata/dats/dat-lock.json)", sys, err)
		}
	}

	// The refusal half: one tampered corpus byte must fail the gate.
	if err := os.WriteFile(filepath.Join(dir, "gb.dat"), []byte("tampered corpus bytes"), 0o644); err != nil {
		t.Fatal(err)
	}
	err = CheckLock(dir, "gb")
	if err == nil {
		t.Fatal("CheckLock after tampering the corpus gb.dat = nil, want *LockMismatch")
	}
	var mm *LockMismatch
	if !errors.As(err, &mm) {
		t.Fatalf("CheckLock error = %T (%v), want *LockMismatch", err, err)
	}
	if mm.SystemKey != "gb" || mm.OnDiskSHA == mm.Entry.BytesSHA256 {
		t.Errorf("mismatch detail = %+v", mm)
	}
}

func mustSystems(t *testing.T, st *store.Store) []store.SystemRow {
	t.Helper()
	systems, err := st.Systems()
	if err != nil {
		t.Fatal(err)
	}
	return systems
}
