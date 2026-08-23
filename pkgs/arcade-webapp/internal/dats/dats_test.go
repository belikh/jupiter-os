package dats

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/fixture"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// stubDats serves a deterministic Fresh1G1R-shaped tree: /<encoded rel
// path> -> the fixture DAT bytes. It records every requested path so the
// tests assert the exact URLs the fetcher builds (the encoding is
// load-bearing: spaces, parens, ampersands).
func stubDats(t *testing.T, hits *[]string) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// RequestURI is the raw wire form — URL.Path comes back
		// DECODED, which would hide an encoding bug.
		*hits = append(*hits, r.RequestURI)
		// Map back to a fixture DAT by collection dir shape only — the
		// stub accepts any <coll>/<name>.dat and serves the gb fixture.
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

	f := &Fetcher{BaseURL: srv.URL, Dir: dir, St: st}
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
	// The URLs the stub saw are exactly BaseURL + encoded collection paths.
	wantPaths := map[string]bool{
		"/no-intro/Nintendo%20-%20Nintendo%20Entertainment%20System%20%28Headerless%29%20%28No-Intro%20-%20Fresh1G1R%20-%20McLean%29.dat": true,
		"/redump/Sega%20-%20Mega%20CD%20%26%20Sega%20CD%20%28Redump%20-%20Fresh1G1R%20-%20McLean%29.dat":                                  true,
	}
	if len(hits) != 2 {
		t.Fatalf("stub saw %d requests (%v), want 2", len(hits), hits)
	}
	for _, h := range hits {
		if !wantPaths[h] {
			t.Errorf("unexpected fetch URL: %s", h)
		}
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

func TestRefreshPerSystemFailuresNeverAbortBatch(t *testing.T) {
	st := openStore(t)
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if atomic.AddInt32(&calls, 2) == 2 { // first request (nes) fails
			w.WriteHeader(http.StatusNotFound)
			return
		}
		_, _ = w.Write([]byte(fixture.DAT(fixture.Systems()[2])))
	}))
	t.Cleanup(srv.Close)

	f := &Fetcher{BaseURL: srv.URL, Dir: filepath.Join(t.TempDir(), "dats"), St: st}
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
	srv := stubDats(t, &[]string{})
	f := &Fetcher{BaseURL: srv.URL, Dir: filepath.Join(t.TempDir(), "dats"), St: st}
	systems := mustSystems(t, st)

	// wiiu: deliberately unmapped — a distinct, checkable error.
	if err := f.RefreshSystem(context.Background(), systems[2]); err == nil || !strings.Contains(err.Error(), "no McLean DAT mapping") {
		t.Errorf("RefreshSystem(wiiu) err = %v, want ErrNotMapped", err)
	}
	// Unreachable host: transport error surfaces, run recorded as error.
	dead := &Fetcher{BaseURL: "http://127.0.0.1:1", Dir: filepath.Join(t.TempDir(), "dats"), St: st}
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
	u := URLFor("http://stub/dats", "nes")
	if !strings.HasPrefix(u, "http://stub/dats/no-intro/") || !strings.HasSuffix(u, ".dat") || strings.ContainsAny(u, " ()") {
		t.Errorf("URLFor(nes) = %q, want encoded no-intro URL", u)
	}
	if u := URLFor("http://stub", "wiiu"); u != "" {
		t.Errorf("URLFor(wiiu) = %q, want empty (unmapped)", u)
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
