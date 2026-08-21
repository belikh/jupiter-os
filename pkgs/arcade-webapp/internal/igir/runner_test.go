package igir

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/fixture"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// fakeIgir writes a shell script that behaves like igir for the flows
// under test: it records its FULL argv, then (optionally) copies the
// staged inputs into --output and writes a FOUND-per-input report CSV to
// --report-output. Env knobs: FAKE_IGIR_FAIL_INPUT (exit 1 when --input
// equals this path — the report is still written, like igir's partial
// reports), FAKE_IGIR_NO_REPORT (skip writing the report).
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
  {
    printf '%s\n' 'DAT Name,Game Name,Status,ROM Files,Patched,BIOS,Retail Release,Unlicensed,Debug,Demo,Beta,Sample,Prototype,Program,Aftermarket,Homebrew,Bad'
    if [ -n "$out" ]; then
      for f in "$in"/*; do
        [ -f "$f" ] || continue
        b="$(basename "$f")"
        printf '%s\n' "Fake DAT,$b,FOUND,$out/$b,false,false,true,false,false,false,false,false,false,false,false,false"
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
	r.runner = New(Config{
		Binary:        fakeIgir(t, root),
		IncomingDir:   r.incoming,
		DATDir:        r.datDir,
		CartridgeRoot: r.cartr,
		OpticalRoot:   r.optical,
		ModernRoot:    r.modern,
		ReportDir:     r.reports,
	}, st, func() error { r.rescans++; return nil }, nil)
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
// the flag set proven on europa (scripts/cartridge-verify.sh:104-113).
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

// ---- report parser ---------------------------------------------------------

func TestParseReportRealShape(t *testing.T) {
	f, err := os.Open(filepath.Join("testdata", "real-shape-nes.csv"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close() //nolint:errcheck // test
	// The committed report from a REAL igir 5.3.0 run over the fixture
	// corpus (make fixture-arcade): 5 FOUND rows, zero anything else.
	rep, err := ParseReport(f, "/home/io/Projects/jupiter-os/tests/fixtures/arcade/verified/nes")
	if err != nil {
		t.Fatal(err)
	}
	if rep.Found != 5 || rep.Missing != 0 || rep.Unmatched != 0 || rep.Duplicate != 0 || rep.Other != 0 {
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
	rep, err := ParseReport(f, "/out/nes")
	if err != nil {
		t.Fatal(err)
	}
	// 3 FOUND, 1 MISSING, 2 UNUSED, 1 DUPLICATE; dat games = found+missing.
	if rep.Found != 3 || rep.Missing != 1 || rep.Unmatched != 2 || rep.Duplicate != 1 || rep.Other != 0 {
		t.Errorf("counts = %+v, want 3/1/2/1/0", rep)
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
}

func TestParseReportQuotedCommas(t *testing.T) {
	f, err := os.Open(filepath.Join("testdata", "quoted-commas.csv"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close() //nolint:errcheck // test
	rep, err := ParseReport(f, "/out/c64")
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
	rep, err := ParseReport(f, "/out/nes")
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
	rep, err = ParseReport(f2, "")
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
	if _, err := ParseReport(strings.NewReader("a,b,c\n1,2,3\n"), ""); err == nil {
		t.Error("a CSV without a Status column must be rejected")
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
