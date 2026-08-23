package igir

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/fixture"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/pipeline"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// fakeIgir writes a shell script that behaves like igir for the flows
// under test: it records its FULL argv, then (optionally) copies the
// staged inputs into --output and writes a FOUND-per-input report CSV to
// --report-output. Env knobs: FAKE_IGIR_FAIL_INPUT (exit 1 when --input
// equals this path — the report is still written, like igir's partial
// reports), FAKE_IGIR_NO_REPORT (skip writing the report),
// FAKE_IGIR_CRC / FAKE_IGIR_SHA1 (emit CRC32/SHA1 report columns with
// these values on every FOUND row — newer igir's hash columns).
//
// The script is a test double for the REAL igir the VM test exercises
// (module option igirPackage); unit tests must stay offline + fast.
func fakeIgir(t *testing.T, dir string) string {
	t.Helper()
	path := filepath.Join(dir, "igir")
	script := `#!/bin/sh
# record the exact argv, one arg per line
printf '%s\n' "$@" > "$FAKE_IGIR_ARGS"
in=""; out=""; rep=""
while [ $# -gt 0 ]; do
  case "$1" in
    --input) in="$2"; shift 2 ;;
    --output) out="$2"; shift 2 ;;
    --report-output) rep="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "$out" ]; then
  mkdir -p "$out"
  for f in "$in"/*; do
    [ -f "$f" ] && cp "$f" "$out/"
  done
fi
if [ -n "$rep" ] && [ -z "$FAKE_IGIR_NO_REPORT" ]; then
  mkdir -p "$(dirname "$rep")"
  crc="${FAKE_IGIR_CRC:-}"; sha="${FAKE_IGIR_SHA1:-}"
  hashcols=""; hashcells=""
  if [ -n "$crc" ] || [ -n "$sha" ]; then
    hashcols=",CRC32,SHA1"; hashcells=",$crc,$sha"
  fi
  {
    printf '%s\n' "DAT Name,Game Name,Status,ROM Files,Patched,BIOS,Retail Release,Unlicensed,Debug,Demo,Beta,Sample,Prototype,Program,Aftermarket,Homebrew,Bad$hashcols"
    if [ -n "$out" ]; then
      for f in "$in"/*; do
        [ -f "$f" ] || continue
        b="$(basename "$f")"
        printf '%s\n' "Fake DAT,$b,FOUND,$out/$b,false,false,true,false,false,false,false,false,false,false,false,false,false$hashcells"
      done
    fi
  } > "$rep"
fi
if [ -n "$FAKE_IGIR_FAIL_INPUT" ] && [ "$in" = "$FAKE_IGIR_FAIL_INPUT" ]; then
  exit 1
fi
exit 0
`
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// rig is one runner test fixture: store with a small catalogue (an
// optical system included for bucket routing), tree roots, fake igir.
type rig struct {
	t        *testing.T
	st       *store.Store
	runner   *Runner
	root     string
	incoming string
	datDir   string
	reports  string
	cartr    string
	optical  string
	modern   string
	argsFile string
	rescans  int
}

func newRig(t *testing.T, systems ...store.SystemRow) *rig {
	t.Helper()
	if len(systems) == 0 {
		systems = []store.SystemRow{
			{Key: "nes", Collection: "NES", Bucket: "cartridge", SortOrder: 1, Extensions: `["nes"]`},
			{Key: "segacd", Collection: "Sega CD", Bucket: "optical", SortOrder: 2, Extensions: `["cue","bin"]`},
		}
	}
	root := t.TempDir()
	r := &rig{
		t:        t,
		root:     root,
		incoming: filepath.Join(root, "incoming"),
		datDir:   filepath.Join(root, "dats"),
		reports:  filepath.Join(root, "scratch", "reports"),
		cartr:    filepath.Join(root, "games", "cartridge"),
		optical:  filepath.Join(root, "games", "optical"),
		modern:   filepath.Join(root, "games", "modern"),
	}
	for _, d := range []string{r.incoming, r.datDir, r.cartr, r.optical, r.modern} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	st, err := store.Open(filepath.Join(root, "arcade.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() }) //nolint:errcheck // test
	if err := st.UpsertSystems(systems); err != nil {
		t.Fatal(err)
	}
	r.st = st
	r.argsFile = filepath.Join(root, "argv")
	runner, err := New(Config{
		Binary:        fakeIgir(t, root),
		IncomingDir:   r.incoming,
		DATDir:        r.datDir,
		CartridgeRoot: r.cartr,
		OpticalRoot:   r.optical,
		ModernRoot:    r.modern,
		ReportDir:     r.reports,
	}, st, func() error { r.rescans++; return nil }, nil)
	if err != nil {
		t.Fatal(err)
	}
	r.runner = runner
	t.Setenv("FAKE_IGIR_ARGS", r.argsFile)
	return r
}

// stage writes deterministic ROM files under incoming/<sys>/.
func (r *rig) stage(sys string, names ...string) {
	dir := filepath.Join(r.incoming, sys)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		r.t.Fatal(err)
	}
	for i, n := range names {
		p := filepath.Join(dir, n)
		b := fixture.RomBytes(sys+"/"+n, 1024+i)
		if err := os.WriteFile(p, b, 0o644); err != nil {
			r.t.Fatal(err)
		}
	}
}

func (r *rig) stageDAT(sys string) {
	if err := os.MkdirAll(r.datDir, 0o755); err != nil {
		r.t.Fatal(err)
	}
	// Any parseable Logiqx DAT shape works — the fake igir never reads it.
	if err := os.WriteFile(filepath.Join(r.datDir, sys+".dat"), []byte(fixture.DAT(fixture.Systems()[0])), 0o644); err != nil {
		r.t.Fatal(err)
	}
}

func (r *rig) argv() []string {
	b, err := os.ReadFile(r.argsFile)
	if err != nil {
		return nil
	}
	var args []string
	for _, line := range strings.Split(strings.TrimRight(string(b), "\n"), "\n") {
		args = append(args, line)
	}
	return args
}

func (r *rig) verifyResult(sys string) *store.VerifyResult {
	rows, err := r.st.SystemSummary()
	if err != nil {
		r.t.Fatal(err)
	}
	for _, row := range rows {
		if row.Key == sys && row.VerifyPresent {
			v := row.Verify
			return &v
		}
	}
	return nil
}

// TestArgvMatchesCartridgeVerifyScript pins the EXACT igir invocation —
// the flag set proven on europa (scripts/cartridge-verify.sh:104-113)
// plus the webapp's one deliberate addition: --input-exclude
// <input>/**/*.torrent (D-P3e — aria2 drops infohash .torrent metadata
// companions into every download dir even via addTorrent, proven
// empirically against the pinned aria2 1.37.0; no DAT can claim a
// .torrent, so the exclusion cannot hide a real deviation, and the
// served report carries zero unmatched rows for them). The glob MUST be
// anchored to the absolute input dir: igir expands exclude globs
// against the filesystem from the process cwd (a bare **/*.torrent from
// cwd=/ crawls the whole tree — proven: EACCES scandir '/root' as a
// user, the minutes-long nix-store walk as root, the P3 VM hang).
func TestArgvMatchesCartridgeVerifyScript(t *testing.T) {
	r := newRig(t)
	r.stage("nes", "Starlit Vault (USA).nes")
	r.stageDAT("nes")

	outcomes, err := r.runner.Verify([]string{"nes"})
	if err != nil {
		t.Fatal(err)
	}
	if outcomes[0].Outcome != OutcomeVerified {
		t.Fatalf("outcome = %+v, want verified", outcomes[0])
	}
	want := []string{
		"copy", "test", "report",
		"--dat", filepath.Join(r.datDir, "nes.dat"),
		"--input", filepath.Join(r.incoming, "nes"),
		"--output", filepath.Join(r.cartr, "nes"),
		"--report-output", filepath.Join(r.reports, "nes.csv"),
		"--input-checksum-max", "CRC32",
		"--input-exclude", filepath.Join(r.incoming, "nes", "**", "*.torrent"),
		"--dir-game-subdir", "never",
		"--reader-threads", "2",
		"--writer-threads", "2",
		"--dat-threads", "1",
	}
	if got := r.argv(); !reflect.DeepEqual(got, want) {
		t.Errorf("igir argv =\n  %v\nwant\n  %v", got, want)
	}
}

// TestBucketRoutingFromCatalogue proves the output dir follows the
// catalogue bucket column (segacd → optical root, nes → cartridge root).
func TestBucketRoutingFromCatalogue(t *testing.T) {
	r := newRig(t)
	r.stage("segacd", "Turbo Disc (USA).cue")
	r.stageDAT("segacd")

	if _, err := r.runner.Verify([]string{"segacd"}); err != nil {
		t.Fatal(err)
	}
	if got := r.argv(); !strings.Contains(strings.Join(got, " "), "--output "+filepath.Join(r.optical, "segacd")) {
		t.Errorf("segacd output not routed to the optical bucket: %v", got)
	}
	// The fake igir copied the staged file into the routed output.
	if _, err := os.Stat(filepath.Join(r.optical, "segacd", "Turbo Disc (USA).cue")); err != nil {
		t.Errorf("promoted file missing in optical tree: %v", err)
	}
}

// TestSkips: nothing staged → skipped-empty (igir NOT invoked, no
// verify_results row — idempotence, the script's first guard); staged
// but holding .aria2 control files → skipped-downloading (the whole
// system is skipped: partial files cannot DAT-match).
func TestSkips(t *testing.T) {
	r := newRig(t)

	oc, err := r.runner.Verify([]string{"nes"})
	if err != nil {
		t.Fatal(err)
	}
	if oc[0].Outcome != OutcomeSkippedEmpty {
		t.Errorf("empty system outcome = %s, want skipped-empty", oc[0].Outcome)
	}
	if r.argv() != nil {
		t.Error("igir must not run for an empty system")
	}
	if v := r.verifyResult("nes"); v != nil {
		t.Error("skipped-empty must not record a verify_results row")
	}

	r.stage("nes", "Half A ROM (Japan).nes")
	if err := os.WriteFile(filepath.Join(r.incoming, "nes", "Half A ROM (Japan).nes.aria2"), []byte("ctrl"), 0o644); err != nil {
		t.Fatal(err)
	}
	_ = os.Remove(r.argsFile) // reset argv capture
	oc, err = r.runner.Verify([]string{"nes"})
	if err != nil {
		t.Fatal(err)
	}
	if oc[0].Outcome != OutcomeSkippedDownloading {
		t.Errorf("in-flight system outcome = %s, want skipped-downloading", oc[0].Outcome)
	}
	if r.argv() != nil {
		t.Error("igir must not run while .aria2 control files are present")
	}
	if v := r.verifyResult("nes"); v != nil {
		t.Error("in-flight skip must not record a verify_results row")
	}
}

// TestMissingDATPromotesUnchecked: cartridge-verify.sh's degradation —
// no DAT → copy staged ROMs as-is into the bucket tree, record an
// UNCHECKED verify result, leave game states alone. Re-run copies
// nothing (rsync quick-check semantics).
func TestMissingDATPromotesUnchecked(t *testing.T) {
	r := newRig(t)
	r.stage("nes", "A (USA).nes", "B (Europe).nes")

	oc, err := r.runner.Verify([]string{"nes"})
	if err != nil {
		t.Fatal(err)
	}
	if oc[0].Outcome != OutcomePromotedUnchecked {
		t.Fatalf("outcome = %s, want promoted-unchecked", oc[0].Outcome)
	}
	if oc[0].CopiedFiles != 2 || oc[0].PromotedBytes != 1024+1025 {
		t.Errorf("unchecked promote = %d files / %d bytes, want 2 / 2049", oc[0].CopiedFiles, oc[0].PromotedBytes)
	}
	for _, n := range []string{"A (USA).nes", "B (Europe).nes"} {
		if _, err := os.Stat(filepath.Join(r.cartr, "nes", n)); err != nil {
			t.Errorf("unchecked file not promoted: %v", err)
		}
	}
	v := r.verifyResult("nes")
	if v == nil || v.Unchecked != 1 || v.PromotedBytes != 2049 {
		t.Errorf("verify_results = %+v, want unchecked row with 2049 promoted bytes", v)
	}

	// Re-run: quick-check skips identical files (size+mtime equal).
	oc, err = r.runner.Verify([]string{"nes"})
	if err != nil {
		t.Fatal(err)
	}
	if oc[0].CopiedFiles != 0 || oc[0].PromotedBytes != 0 {
		t.Errorf("re-run unchecked promote copied %d files / %d bytes, want 0/0 (quick-check)", oc[0].CopiedFiles, oc[0].PromotedBytes)
	}

	// The post-promote rescan hook fired (promoted files become game rows).
	if r.rescans == 0 {
		t.Error("rescan hook never fired after a promoting verify")
	}
}

// TestIngestionFlipsGameStates: the report's FOUND rows flip the
// matching games-table rows to 'verified' (by output-relative path) and
// everything else to 'unmatched'; the aggregates land in verify_results.
func TestIngestionFlipsGameStates(t *testing.T) {
	r := newRig(t)
	r.stage("nes", "A (USA).nes", "B (Europe).nes")
	r.stageDAT("nes")

	// Pre-existing games rows: one the report will claim, one it won't.
	now := time.Now().UTC()
	if err := r.st.ReplaceSystemGames("nes", []store.GameRow{
		{RelPath: "A (USA).nes", SizeBytes: 1024},
		{RelPath: "stray.zip", SizeBytes: 7},
	}, now); err != nil {
		t.Fatal(err)
	}

	oc, err := r.runner.Verify([]string{"nes"})
	if err != nil {
		t.Fatal(err)
	}
	if oc[0].Outcome != OutcomeVerified || oc[0].Found != 2 || oc[0].Unmatched != 0 {
		t.Fatalf("outcome = %+v, want verified 2 found", oc[0])
	}
	v := r.verifyResult("nes")
	if v == nil || v.Found != 2 || v.DatGames != 2 || v.Unchecked != 0 {
		t.Errorf("verify_results = %+v, want 2/2 found checked row", v)
	}
	var aState, strayState string
	aState = r.st.GameVerifyState("nes", "A (USA).nes")
	strayState = r.st.GameVerifyState("nes", "stray.zip")
	if aState != "verified" {
		t.Errorf("claimed game state = %q, want verified", aState)
	}
	if strayState != "unmatched" {
		t.Errorf("unclaimed game state = %q, want unmatched (DAT is authoritative)", strayState)
	}
	// Promoted bytes reflect the on-disk FOUND outputs.
	if oc[0].PromotedBytes != 1024+1025 {
		t.Errorf("promoted bytes = %d, want 2049", oc[0].PromotedBytes)
	}
	// The verify run is recorded with the per-system detail.
	run, _ := r.st.LastRun()
	if run == nil || run.Kind != "verify" || !strings.Contains(run.Detail, `"Outcome":"verified"`) {
		t.Errorf("run = %+v, want verify run with outcome detail", run)
	}
}

// TestChecksumsIngestedFromReport (P5): when the fake igir's report
// carries CRC32/SHA1 columns, the FOUND rows' hashes persist into
// games.crc32/sha1 keyed by output-relative path; a re-verify with the
// columns absent must NOT erase them (selective update).
func TestChecksumsIngestedFromReport(t *testing.T) {
	r := newRig(t)
	r.stage("nes", "A (USA).nes")
	r.stageDAT("nes")
	now := time.Now().UTC()
	if err := r.st.ReplaceSystemGames("nes", []store.GameRow{
		{RelPath: "A (USA).nes", SizeBytes: 1024},
	}, now); err != nil {
		t.Fatal(err)
	}

	// First verify: report carries hash columns.
	t.Setenv("FAKE_IGIR_CRC", "deadbeef")
	t.Setenv("FAKE_IGIR_SHA1", "aaa111")
	if _, err := r.runner.Verify([]string{"nes"}); err != nil {
		t.Fatal(err)
	}
	d, err := r.st.GetGame("nes", mustGameID(r.t, r.st, "nes"))
	if err != nil || d == nil {
		t.Fatalf("GetGame: %v, %v", d, err)
	}
	if d.CRC32 != "deadbeef" || d.SHA1 != "aaa111" {
		t.Errorf("ingested checksums = %s/%s, want deadbeef/aaa111", d.CRC32, d.SHA1)
	}

	// Second verify WITHOUT hash columns: prior values must survive.
	if err := os.Unsetenv("FAKE_IGIR_CRC"); err != nil {
		t.Fatal(err)
	}
	if err := os.Unsetenv("FAKE_IGIR_SHA1"); err != nil {
		t.Fatal(err)
	}
	if _, err := r.runner.Verify([]string{"nes"}); err != nil {
		t.Fatal(err)
	}
	d, _ = r.st.GetGame("nes", mustGameID(r.t, r.st, "nes"))
	if d.CRC32 != "deadbeef" || d.SHA1 != "aaa111" {
		t.Errorf("checksums after hash-less re-verify = %s/%s, want preserved deadbeef/aaa111", d.CRC32, d.SHA1)
	}
}

// mustGameID fetches the single game row's id for sys.
func mustGameID(t *testing.T, st *store.Store, sys string) int64 {
	t.Helper()
	page, err := st.ListGames(store.GameListOpts{SystemKey: sys})
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Games) != 1 {
		t.Fatalf("%s games = %d rows, want 1", sys, len(page.Games))
	}
	return page.Games[0].ID
}

// TestIgirNonZeroExitIsWarningNotAbort: a failing igir that still wrote
// a report records its counts with a failed outcome; the next system in
// the batch still runs (subshell-per-system isolation).
func TestIgirNonZeroExitIsWarningNotAbort(t *testing.T) {
	r := newRig(t)
	r.stage("nes", "A (USA).nes")
	r.stageDAT("nes")
	r.stage("segacd", "T (USA).cue")
	r.stageDAT("segacd")

	t.Setenv("FAKE_IGIR_FAIL_INPUT", filepath.Join(r.incoming, "nes"))
	oc, err := r.runner.Verify([]string{"nes", "segacd"})
	if err != nil {
		t.Fatal(err)
	}
	if oc[0].Outcome != OutcomeFailed || !strings.Contains(oc[0].Err, "igir exited non-zero") {
		t.Errorf("nes outcome = %+v, want failed with non-zero-exit error", oc[0])
	}
	if oc[0].Found != 1 {
		t.Errorf("failed igir still ingested Found = %d, want 1 (report parsed)", oc[0].Found)
	}
	if oc[1].Outcome != OutcomeVerified {
		t.Errorf("segacd outcome = %s, want verified (batch not aborted)", oc[1].Outcome)
	}
}

// TestMissingReportFailsSystem: igir "succeeds" but no report lands →
// failed outcome with a parse error, no verify_results row.
func TestMissingReportFailsSystem(t *testing.T) {
	r := newRig(t)
	r.stage("nes", "A (USA).nes")
	r.stageDAT("nes")
	t.Setenv("FAKE_IGIR_NO_REPORT", "1")

	oc, err := r.runner.Verify([]string{"nes"})
	if err != nil {
		t.Fatal(err)
	}
	if oc[0].Outcome != OutcomeFailed || !strings.Contains(oc[0].Err, "report") {
		t.Errorf("outcome = %+v, want failed with report error", oc[0])
	}
	if v := r.verifyResult("nes"); v != nil {
		t.Error("no report → no verify_results row")
	}
}

// TestPipelineMutexBlocksVerify pins the igir half of ADV-P5-03: with
// the shared verify+scrape slot held (a scrape running), Verify refuses
// with exactly ErrBusy — nothing recorded, no exec — and runs normally
// once the slot frees.
func TestPipelineMutexBlocksVerify(t *testing.T) {
	r := newRig(t)
	r.stage("nes", "A (USA).nes")
	r.stageDAT("nes")

	var lock pipeline.Mutex
	if !lock.TryAcquire() {
		t.Fatal("could not claim a fresh pipeline lock")
	}
	r.runner.Pipeline = &lock

	argsBefore := len(r.argv())
	if _, err := r.runner.Verify([]string{"nes"}); err != ErrBusy {
		t.Errorf("Verify while scrape holds the pipeline = %v, want ErrBusy", err)
	}
	if got := len(r.argv()); got != argsBefore {
		t.Errorf("igir exec'd %d arg lines while pipeline-busy, want none", got-argsBefore)
	}

	lock.Release()
	if _, err := r.runner.Verify([]string{"nes"}); err != nil {
		t.Errorf("Verify after release: %v, want nil", err)
	}
}

// TestErrBusyAndUnknownSystem: a second concurrent Verify is rejected;
// an unknown system key is a failed outcome, not a panic.
func TestErrBusyAndUnknownSystem(t *testing.T) {
	r := newRig(t)
	r.stage("nes", "A (USA).nes")
	r.stageDAT("nes")

	r.runner.setState(func(s *State) { s.Running = true })
	if _, err := r.runner.Verify([]string{"nes"}); err != ErrBusy {
		t.Errorf("concurrent Verify err = %v, want ErrBusy", err)
	}
	r.runner.setState(func(s *State) { s.Running = false })

	oc, err := r.runner.Verify([]string{"nope"})
	if err != nil {
		t.Fatal(err)
	}
	if oc[0].Outcome != OutcomeFailed || !strings.Contains(oc[0].Err, "unknown system") {
		t.Errorf("unknown system outcome = %+v", oc[0])
	}
}

// TestUnconfiguredRunner: no binary → error naming the gap.
func TestUnconfiguredRunner(t *testing.T) {
	r := newRig(t)
	r.runner.cfg.Binary = ""
	if r.runner.Configured() {
		t.Fatal("empty binary must read as unconfigured")
	}
	// Verify still runs (store-driven) but every system fails fast.
	oc, err := r.runner.Verify([]string{"nes"})
	if err != nil {
		t.Fatal(err)
	}
	if oc[0].Outcome == OutcomeVerified {
		t.Error("unconfigured runner must not report verified")
	}
}

// TestNewRejectsRelativeRoots (ADV-P3-03): igir resolves relative path
// arguments (and expands the --input-exclude glob) against its process
// cwd, so a relative config root would silently re-arm exactly the
// cwd-rooted crawl the input-anchored exclude exists to prevent (the
// run-2/5 VM hang, D-P3e). Construction must fail loudly instead —
// every path field except Binary is checked (empty included:
// filepath.Join("", sys) yields a bare relative key). The module always
// passes absolute paths; this guard is for hand-rolled envs.
func TestNewRejectsRelativeRoots(t *testing.T) {
	dir := t.TempDir()
	cfg := Config{
		Binary:        "/bin/true",
		IncomingDir:   filepath.Join(dir, "incoming"),
		DATDir:        filepath.Join(dir, "dats"),
		CartridgeRoot: filepath.Join(dir, "games", "cartridge"),
		OpticalRoot:   filepath.Join(dir, "games", "optical"),
		ModernRoot:    filepath.Join(dir, "games", "modern"),
		ReportDir:     filepath.Join(dir, "scratch", "reports"),
	}
	if r, err := New(cfg, nil, nil, nil); err != nil || r == nil {
		t.Fatalf("all-absolute config must build (runner=%v, err=%v)", r, err)
	}
	for _, field := range []string{"IncomingDir", "DATDir", "CartridgeRoot", "OpticalRoot", "ModernRoot", "ReportDir"} {
		for _, bad := range []string{"relative/path", ""} {
			mut := cfg
			reflect.ValueOf(&mut).Elem().FieldByName(field).SetString(bad)
			_, err := New(mut, nil, nil, nil)
			if err == nil || !strings.Contains(err.Error(), field) || (bad != "" && !strings.Contains(err.Error(), bad)) {
				t.Errorf("Config.%s = %q must fail construction naming the field and path (got err=%v)", field, bad, err)
			}
		}
	}
}

// ---- report parser ---------------------------------------------------------

func TestParseReportRealShape(t *testing.T) {
	f, err := os.Open(filepath.Join("testdata", "real-shape-nes.csv"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close() //nolint:errcheck // test
	// The committed report from a REAL igir 5.3.0 run over the fixture
	// corpus (make fixture-arcade): 5 FOUND rows, zero anything else.
	rep, err := ParseReport(f,
		"/home/io/Projects/jupiter-os/tests/fixtures/arcade/incoming/nes",
		"/home/io/Projects/jupiter-os/tests/fixtures/arcade/verified/nes")
	if err != nil {
		t.Fatal(err)
	}
	if rep.Found != 5 || rep.Missing != 0 || rep.Unmatched != 0 || rep.Duplicate != 0 || rep.Extra != 0 || rep.Other != 0 {
		t.Errorf("counts = %+v, want 5 FOUND only", rep)
	}
	if len(rep.FoundRels) != 5 || rep.FoundRels[0] != "Crystal Carp (USA) (Rev A).nes" {
		t.Errorf("FoundRels = %v", rep.FoundRels)
	}
}

func TestParseReportEdgeShapes(t *testing.T) {
	f, err := os.Open(filepath.Join("testdata", "edge-shapes.csv"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close() //nolint:errcheck // test
	rep, err := ParseReport(f, "/incoming/nes", "/out/nes")
	if err != nil {
		t.Fatal(err)
	}
	// 3 FOUND, 1 MISSING; input-side: 2 UNUSED + 1 DUPLICATE (staged
	// duplicate of an already-FOUND game); output-side: 1 DUPLICATE echo
	// + 1 UNUSED extra (games-tree file the DAT doesn't claim).
	if rep.Found != 3 || rep.Missing != 1 || rep.Unmatched != 3 || rep.Duplicate != 1 || rep.Extra != 1 || rep.Other != 0 {
		t.Errorf("counts = %+v, want 3/1/3/1/1/0", rep)
	}
	if rep.DatGames != 4 {
		t.Errorf("DatGames = %d, want 4 (found+missing)", rep.DatGames)
	}
	wantRels := []string{
		"Starlit Vault (USA).nes",
		"Mecha Garden (Japan).nes",
		"Bootleg Multi (World).nes",
	}
	if !reflect.DeepEqual(rep.FoundRels, wantRels) {
		t.Errorf("FoundRels = %v, want %v", rep.FoundRels, wantRels)
	}
	// P4 drill-down: the per-file offenders behind Unmatched/Extra —
	// input-side UNUSED/DUPLICATE basenames (red) and output-side UNUSED
	// basenames (amber), in report order. The output-side DUPLICATE echo
	// is benign and must NOT be listed.
	wantUnmatchedFiles := []string{
		"Starlit Vault (USA) [1].nes",
		"readme.txt",
		"bad dump.nes",
	}
	if !reflect.DeepEqual(rep.UnmatchedFiles, wantUnmatchedFiles) {
		t.Errorf("UnmatchedFiles = %v, want %v", rep.UnmatchedFiles, wantUnmatchedFiles)
	}
	wantExtraFiles := []string{"Bonza Box (USA).zip"}
	if !reflect.DeepEqual(rep.ExtraFiles, wantExtraFiles) {
		t.Errorf("ExtraFiles = %v, want %v", rep.ExtraFiles, wantExtraFiles)
	}
}

// TestParseReportChecksumColumns (P5): when the report carries CRC32/SHA1
// columns (newer igir), the FOUND rows' hashes ride back aligned with
// FoundRels by index; empty cells parse as empty strings and a MISSING
// row contributes nothing. Reports WITHOUT the columns keep parsing
// identically (covered by every other parser test).
func TestParseReportChecksumColumns(t *testing.T) {
	f, err := os.Open(filepath.Join("testdata", "checksum-columns.csv"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close() //nolint:errcheck // test
	rep, err := ParseReport(f, "/in/nes", "/out/nes")
	if err != nil {
		t.Fatal(err)
	}
	if rep.Found != 4 || rep.Missing != 1 {
		t.Fatalf("counts = %+v, want 4 FOUND / 1 MISSING", rep)
	}
	wantCRCs := []string{"deadbeef", "", "", "cafebabe"}
	wantSHAs := []string{"aaa1112223334445556667778889990001112223", "bbb2223334445556667778889990001112223334", "", ""}
	if !reflect.DeepEqual(rep.FoundCRCs, wantCRCs) || !reflect.DeepEqual(rep.FoundSHAs, wantSHAs) {
		t.Errorf("checksum columns = %v / %v\nwant           %v / %v", rep.FoundCRCs, rep.FoundSHAs, wantCRCs, wantSHAs)
	}
	if len(rep.FoundCRCs) != len(rep.FoundRels) || len(rep.FoundSHAs) != len(rep.FoundPaths) {
		t.Errorf("hash slices not index-aligned with paths/rels: %d/%d vs %d",
			len(rep.FoundCRCs), len(rep.FoundSHAs), len(rep.FoundPaths))
	}
}

func TestParseReportQuotedCommas(t *testing.T) {
	f, err := os.Open(filepath.Join("testdata", "quoted-commas.csv"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close() //nolint:errcheck // test
	rep, err := ParseReport(f, "/in", "/out/c64")
	if err != nil {
		t.Fatal(err)
	}
	if rep.Found != 1 || rep.Unmatched != 1 {
		t.Errorf("counts = %+v, want 1 FOUND / 1 UNUSED with quoted commas", rep)
	}
	if len(rep.FoundRels) != 1 || rep.FoundRels[0] != "Game, With Comma (USA).prg" {
		t.Errorf("FoundRels = %v (quoted-comma name must survive)", rep.FoundRels)
	}
}

func TestParseReportCRLFAndUnknownStatuses(t *testing.T) {
	f, err := os.Open(filepath.Join("testdata", "crlf-shape.csv"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close() //nolint:errcheck // test
	rep, err := ParseReport(f, "/in", "/out/nes")
	if err != nil {
		t.Fatal(err)
	}
	if rep.Found != 1 || rep.Unmatched != 1 {
		t.Errorf("CRLF counts = %+v, want 1/1", rep)
	}

	f2, err := os.Open(filepath.Join("testdata", "ragged-unknown.csv"))
	if err != nil {
		t.Fatal(err)
	}
	defer f2.Close() //nolint:errcheck // test
	rep, err = ParseReport(f2, "", "")
	if err != nil {
		t.Fatal(err)
	}
	// WEIRDSTATE counts as Other (never silently dropped); the
	// empty-status row and the header-length row are skipped.
	if rep.Other != 1 || rep.Found != 0 {
		t.Errorf("ragged counts = %+v, want 1 Other only", rep)
	}
}

func TestParseReportRejectsNonIgirCSV(t *testing.T) {
	if _, err := ParseReport(strings.NewReader("a,b,c\n1,2,3\n"), "", ""); err == nil {
		t.Error("a CSV without a Status column must be rejected")
	}
}

// TestParseReportProvenance is the real-igir bring-up lesson as a unit:
// igir scans BOTH --input and --output, so the SAME status means
// different things per side. Input-side UNUSED/DUPLICATE are staged-set
// deviations (red); output-side UNUSED is a tree extra (amber) and
// output-side DUPLICATE is the idempotent re-verify echo (benign). A row
// on neither side counts as Other (red, conservative).
func TestParseReportProvenance(t *testing.T) {
	csvText := `DAT Name,Game Name,Status,ROM Files
NES,Game A,FOUND,/out/nes/Game A.nes
NES,Game B,MISSING,
,,UNUSED,/in/nes/junk.nes
,,UNUSED,/out/nes/operator drop.zip
,,DUPLICATE,/in/nes/Game A [1].nes
,,DUPLICATE,/out/nes/Game A.nes
,,UNUSED,/nowhere/orphan.bin
`
	rep, err := ParseReport(strings.NewReader(csvText), "/in/nes", "/out/nes")
	if err != nil {
		t.Fatal(err)
	}
	if rep.Found != 1 || rep.Missing != 1 {
		t.Errorf("Found/Missing = %d/%d, want 1/1", rep.Found, rep.Missing)
	}
	if rep.Unmatched != 2 {
		t.Errorf("Unmatched = %d, want 2 (input UNUSED + input DUPLICATE)", rep.Unmatched)
	}
	if rep.Extra != 1 {
		t.Errorf("Extra = %d, want 1 (output UNUSED)", rep.Extra)
	}
	if rep.Duplicate != 1 {
		t.Errorf("Duplicate = %d, want 1 (output echo)", rep.Duplicate)
	}
	if rep.Other != 1 {
		t.Errorf("Other = %d, want 1 (row on neither side)", rep.Other)
	}
}

// TestParseReportLauncherDBArtifacts pins the P6 classification: output-side
// UNUSED rows for the launcher-DB files the pipeline itself writes
// (metadata.pegasus.txt, anything under media/) are ARTIFACTS, not extras.
// Proven against real igir 5.3.0 (P6 VM bring-up + a local probe): igir
// inventories every unknown file in both scanned dirs — it recurses into
// media/ and has no output-side exclude — so without this split every
// verify after a generation would go amber forever. A genuine operator
// drop in the same tree must still count as Extra.
func TestParseReportLauncherDBArtifacts(t *testing.T) {
	csvText := `DAT Name,Game Name,Status,ROM Files
NES,Game A,FOUND,/out/nes/Game A.nes
,,UNUSED,/out/nes/metadata.pegasus.txt
,,UNUSED,/out/nes/media/Game A/cover.png
,,UNUSED,/out/nes/media/screenshot.png
,,UNUSED,/out/nes/operator drop.zip
`
	rep, err := ParseReport(strings.NewReader(csvText), "/in/nes", "/out/nes")
	if err != nil {
		t.Fatal(err)
	}
	if rep.Artifacts != 3 {
		t.Errorf("Artifacts = %d, want 3 (metadata file + two media depths)", rep.Artifacts)
	}
	if rep.Extra != 1 {
		t.Errorf("Extra = %d, want 1 (a real operator drop is still amber)", rep.Extra)
	}
	for _, f := range rep.ArtifactFiles {
		if strings.Contains(f, "operator drop") {
			t.Errorf("real extra misclassified as artifact: %v", rep.ArtifactFiles)
		}
	}
	if len(rep.ExtraFiles) != 1 || !strings.Contains(rep.ExtraFiles[0], "operator drop") {
		t.Errorf("ExtraFiles = %v, want the operator drop only", rep.ExtraFiles)
	}
	// The input side is never artifact-classified: a metadata file staged
	// in incoming/ is junk exactly as before (red).
	csvText = "DAT Name,Game Name,Status,ROM Files\n,,UNUSED,/in/nes/metadata.pegasus.txt\n"
	rep, err = ParseReport(strings.NewReader(csvText), "/in/nes", "/out/nes")
	if err != nil {
		t.Fatal(err)
	}
	if rep.Unmatched != 1 || rep.Artifacts != 0 {
		t.Errorf("input-side metadata file: Unmatched=%d Artifacts=%d, want 1/0", rep.Unmatched, rep.Artifacts)
	}
}

// TestLauncherDBArtifactTmpShape pins the ADV-P6-02 defense in depth:
// the generator's dot-prefixed *.tmp write siblings (kill -9 residue
// between CreateTemp and Rename) classify as launcher-DB artifacts, so a
// verify that runs before the next sweep counts them benign instead of
// amber Extra. Both the pid-stamped current shape and legacy no-pid
// residue match; lookalikes outside the system dir root or with other
// stems do not.
func TestLauncherDBArtifactTmpShape(t *testing.T) {
	out := "/out/nes"
	cases := []struct {
		path string
		want bool
		note string
	}{
		{out + "/metadata.pegasus.txt", true, "the served file"},
		{out + "/.metadata.pegasus.txt.4242.31415926.tmp", true, "pid-stamped residue"},
		{out + "/.metadata.pegasus.txt.534534.tmp", true, "legacy no-pid residue"},
		{out + "/media/x/cover.png", true, "media subtree unchanged"},
		{out + "/.other.pegasus.txt.4242.tmp", false, "different stem"},
		{out + "/sub/.metadata.pegasus.txt.4242.tmp", false, "not at the system-dir root"},
		{out + "/operator drop.tmp", false, "real junk still amber via Extra"},
		{"elsewhere/nes/metadata.pegasus.txt", false, "outside the output dir"},
	}
	for _, tc := range cases {
		if got := launcherDBArtifact(out, tc.path); got != tc.want {
			t.Errorf("%s: launcherDBArtifact = %v, want %v", tc.note, got, tc.want)
		}
	}
}

// ---- copyTree quick-check --------------------------------------------------

func TestCopyTreeQuickCheckSemantics(t *testing.T) {
	src := t.TempDir()
	dst := t.TempDir()
	write := func(dir, name string, b []byte, age time.Time) {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, b, 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(p, age, age); err != nil {
			t.Fatal(err)
		}
	}
	stamp := time.Now().Add(-time.Hour).Truncate(time.Second) // FAT-safe granularity
	write(src, "same.nes", []byte("aaaa"), stamp)
	write(src, "grown.nes", []byte("bb"), stamp)
	write(dst, "same.nes", []byte("aaaa"), stamp)                 // identical: skip
	write(dst, "grown.nes", []byte("bb"), stamp.Add(time.Minute)) // mtime differs: recopy

	bytes, files, err := copyTree(src, dst)
	if err != nil {
		t.Fatal(err)
	}
	if files != 1 || bytes != 2 {
		t.Errorf("copyTree = %d files / %d bytes, want 1 / 2 (only grown.nes)", files, bytes)
	}
	got, _ := os.ReadFile(filepath.Join(dst, "grown.nes"))
	if string(got) != "bb" {
		t.Errorf("grown.nes = %q, want recopied", got)
	}
	// Subdirectories are created, nested files copied.
	if err := os.MkdirAll(filepath.Join(src, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	write(filepath.Join(src, "sub"), "deep.nes", []byte("cccc"), stamp)
	if _, _, err := copyTree(src, dst); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dst, "sub", "deep.nes")); err != nil {
		t.Errorf("nested file not copied: %v", err)
	}
}

// ---- helpers ---------------------------------------------------------------
