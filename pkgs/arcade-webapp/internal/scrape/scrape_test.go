package scrape

import (
	"bytes"
	"errors"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/igir"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/pipeline"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// Invented credential values (house rule, cf. aria2_test.go's testSecret):
// no real fleet secret is ever committed. Their whole job is to be greppable
// everywhere EXCEPT the driver's logs — they MUST reach Skyscraper's exec
// argv and MUST NEVER appear in log output.
const (
	testSSCreds = "unit-test-ss-user:unit-test-ss-pass-not-real"
	testTGDBKey = "unit-test-tgdb-key-not-real"
)

// fakeSkyscraper records each invocation into $FAKE_OUT: a --- separator,
// then every argv element on its own line (line-based parsing keeps args
// with spaces intact), plus the Qt platform env it was handed into
// $FAKE_ENV. Both env vars are set via t.Setenv and inherited through the
// runner's os.Environ().
const fakeSkyscraper = `#!/bin/sh
{
  echo '---'
  for a in "$@"; do
    printf '%s\n' "$a"
  done
} >> "$FAKE_OUT"
echo "${QT_QPA_PLATFORM-unset}" >> "$FAKE_ENV"
`

// harness wires a Driver at a temp world that mirrors one row of the real
// pipeline: fake Skyscraper binary, seeded catalogue store, populated
// platform games tree, credential FILES (paths only, contents invented),
// and an empty resource-cache root.
type harness struct {
	driver   *Driver
	argvPath string // $FAKE_OUT
	envPath  string // $FAKE_ENV
	cartDir  string // cartridge bucket root
	cacheDir string // Driver.CacheDir
	dir      string // <cartDir>/famicom — the platform games tree
}

const (
	hSysKey    = "famicom"
	hSkyHandle = "nes" // deliberately ≠ hSysKey: -p must carry the SkyHandle while -d/-c key on the catalogue key (ADV-P5-01)
)

func newHarness(t *testing.T) *harness {
	t.Helper()
	tmp := t.TempDir()

	fake := filepath.Join(tmp, "skyscraper")
	if err := os.WriteFile(fake, []byte(fakeSkyscraper), 0o755); err != nil {
		t.Fatalf("write fake skyscraper: %v", err)
	}

	st, err := store.Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	t.Cleanup(func() { st.Close() })
	row := store.SystemRow{
		Key:        hSysKey,
		Collection: "Famicom",
		Bucket:     "cartridge",
		Core:       "fceumm_libretro.so",
		SkyHandle:  hSkyHandle,
		Extensions: `["nes","zip"]`,
		SortOrder:  1,
	}
	if err := st.UpsertSystems([]store.SystemRow{row}); err != nil {
		t.Fatalf("UpsertSystems: %v", err)
	}

	cartDir := filepath.Join(tmp, "cartridges")
	dir := filepath.Join(cartDir, hSysKey)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"Aladdin (USA).nes", "Battle City (USA).zip"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("ROM"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	ssCreds := filepath.Join(tmp, "ss-creds")
	if err := os.WriteFile(ssCreds, []byte(testSSCreds+"\n"), 0o400); err != nil {
		t.Fatal(err)
	}
	tgdbKey := filepath.Join(tmp, "tgdb-key")
	if err := os.WriteFile(tgdbKey, []byte(testTGDBKey+"\n"), 0o400); err != nil {
		t.Fatal(err)
	}

	argvPath := filepath.Join(tmp, "argv.txt")
	envPath := filepath.Join(tmp, "env.txt")
	t.Setenv("FAKE_OUT", argvPath)
	t.Setenv("FAKE_ENV", envPath)

	cacheDir := filepath.Join(tmp, "cache")
	return &harness{
		driver: &Driver{
			BinPath:                fake,
			CacheDir:               cacheDir,
			Source:                 "thegamesdb",
			ScreenscraperCredsFile: ssCreds,
			TGDBKeyFile:            tgdbKey,
			Store:                  st,
			CartridgeRoot:          cartDir,
		},
		argvPath: argvPath,
		envPath:  envPath,
		cartDir:  cartDir,
		cacheDir: cacheDir,
		dir:      dir,
	}
}

// readInvocations folds $FAKE_OUT back into per-invocation argv slices.
// A missing file means zero invocations (the skip paths never exec).
func readInvocations(t *testing.T, path string) [][]string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		t.Fatalf("read %s: %v", path, err)
	}
	var invs [][]string
	var cur []string
	flush := func() {
		if cur != nil {
			invs = append(invs, cur)
			cur = nil
		}
	}
	for _, line := range strings.Split(string(b), "\n") {
		switch {
		case line == "---":
			flush()
		case line == "":
			// trailing newline
		default:
			cur = append(cur, line)
		}
	}
	flush()
	return invs
}

// wantFlag asserts flag+value appear ADJACENT somewhere in argv (exact
// token match, order-insensitive between pairs). Bare flags pass "" and
// require presence without a following-value match.
func wantFlag(t *testing.T, label string, argv []string, flag, want string) {
	t.Helper()
	for i, a := range argv {
		if a != flag {
			continue
		}
		if want == "" || (i+1 < len(argv) && argv[i+1] == want) {
			return
		}
		t.Errorf("%s: %s = %q, want %q (argv %q)", label, flag, argv[min(i+1, len(argv)-1)], want, argv)
		return
	}
	t.Errorf("%s: flag %q missing from argv %q", label, flag, argv)
}

func hasBare(argv []string, flag string) bool {
	for _, a := range argv {
		if a == flag {
			return true
		}
	}
	return false
}

func TestScrapeArgvParity(t *testing.T) {
	h := newHarness(t)
	if err := h.driver.ScrapeSystem(hSysKey); err != nil {
		t.Fatalf("ScrapeSystem: %v", err)
	}

	invs := readInvocations(t, h.argvPath)
	if len(invs) != 3 {
		t.Fatalf("captured %d invocations, want 3 (screenscraper / source / pegasus):\n%q", len(invs), invs)
	}
	passA, passB, passC := invs[0], invs[1], invs[2]

	// Pass A: ScreenScraper primary — CRC-exact zips via unpack, free-tier
	// thread cap, creds straight from the file via -u.
	wantFlag(t, "pass A", passA, "-s", "screenscraper")
	wantFlag(t, "pass A", passA, "-t", "1")
	wantFlag(t, "pass A", passA, "--flags", "unattend,unpack")
	wantFlag(t, "pass A", passA, "-u", testSSCreds)

	// Pass B: configured source gap-fills with onlymissing (ScreenScraper
	// ran) and gets the TGDB apikey via -u.
	wantFlag(t, "pass B", passB, "-s", "thegamesdb")
	wantFlag(t, "pass B", passB, "--flags", "unattend,onlymissing")
	wantFlag(t, "pass B", passB, "-u", testTGDBKey)

	// Pass C: pegasus compose — no source, no credentials.
	wantFlag(t, "pass C", passC, "-f", "pegasus")
	wantFlag(t, "pass C", passC, "--flags", "unattend")

	// -d keys on the CATALOGUE KEY (cartridge-scrape.sh's $CACHE_DIR/$platform
	// — the live europa caches sit under our keys), NOT the SkyHandle;
	// only -p carries SkyHandle (ADV-P5-01).
	cacheWant := filepath.Join(h.cacheDir, hSysKey)
	for i, inv := range invs {
		wantFlag(t, "all passes", inv, "-p", hSkyHandle)
		wantFlag(t, "all passes", inv, "-d", cacheWant)
		wantFlag(t, "all passes", inv, "-i", h.dir)
		if hasBare(inv, "-u") && i == 2 {
			t.Errorf("pass C carries credentials unexpectedly: %q", inv)
		}
	}

	// The headless Qt environment reached every invocation.
	env, err := os.ReadFile(h.envPath)
	if err != nil {
		t.Fatalf("read %s: %v", h.envPath, err)
	}
	qtpa := strings.Fields(string(env))
	if len(qtpa) != 3 {
		t.Errorf("recorded %d Qt platform values, want 3: %q", len(qtpa), qtpa)
	}
	for _, v := range qtpa {
		if v != "offscreen" {
			t.Errorf("QT_QPA_PLATFORM = %q, want offscreen (headless service)", v)
		}
	}

	// The per-system launch-line config landed next to the cache.
	if _, err := os.Stat(filepath.Join(h.cacheDir, "config-"+hSysKey+".ini")); err != nil {
		t.Errorf("per-system config ini not written: %v", err)
	}
}

// failingEchoSkyscraper is the ADV-P5-02 leak vector as a stub: a
// "failing Skyscraper" that echoes its OWN argv (credentials included)
// to stderr — exactly what a real failing run does via Qt network errors,
// which embed URLs carrying ssid/sspassword — and exits 1.
const failingEchoSkyscraper = `#!/bin/sh
{
  echo 'failing-echo stub: argv was:'
  for a in "$@"; do
    printf '%s\n' "$a"
  done
} >&2
exit 1
`

// TestScrapeSecretsNeverLogged is the package's house-critical guarantee:
// credential FILE contents travel exec-argv-only. With the standard logger
// captured into a buffer across a full three-pass run, neither marker may
// appear in the log — while BOTH must be provably present in the captured
// argv, so the guarantee can't be won vacuously by never sending them.
//
// The second phase runs the same driver against a FAILING skyscraper that
// echoes its argv into stderr: every pass fails, each tail is folded into
// an error and logged — and the markers must still never surface (the
// [redacted] marker proves output really flowed through the fold).
func TestScrapeSecretsNeverLogged(t *testing.T) {
	h := newHarness(t)

	var logs bytes.Buffer
	log.SetOutput(&logs)
	log.SetFlags(log.LstdFlags)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	if err := h.driver.ScrapeSystem(hSysKey); err != nil {
		t.Fatalf("ScrapeSystem: %v", err)
	}

	out := logs.String()
	if strings.Contains(out, testSSCreds) {
		t.Fatalf("SCREENSCRAPER CREDS LEAKED into logs:\n%s", out)
	}
	if strings.Contains(out, testTGDBKey) {
		t.Fatalf("TGDB KEY LEAKED into logs:\n%s", out)
	}

	// Non-vacuous proof: the secrets WERE handed to the scraper.
	invs := readInvocations(t, h.argvPath)
	if len(invs) != 3 {
		t.Fatalf("captured %d invocations, want 3:\n%q", len(invs), invs)
	}
	wantFlag(t, "pass A", invs[0], "-u", testSSCreds)
	wantFlag(t, "pass B", invs[1], "-u", testTGDBKey)

	// ADV-P5-02: the failing-echo path. Same driver shape, but the binary
	// echoes its argv (markers included) to stderr and exits 1.
	echo := filepath.Join(t.TempDir(), "skyscraper-failing-echo")
	if err := os.WriteFile(echo, []byte(failingEchoSkyscraper), 0o755); err != nil {
		t.Fatal(err)
	}
	h.driver.BinPath = echo

	logs.Reset()
	serr := h.driver.ScrapeSystem(hSysKey)
	if serr == nil {
		t.Fatal("failing-echo ScrapeSystem = nil, want error (all passes failed)")
	}

	out = logs.String()
	if strings.Contains(out, testSSCreds) {
		t.Fatalf("SCREENSCRAPER CREDS LEAKED into logs on the failing-echo path:\n%s", out)
	}
	if strings.Contains(out, testTGDBKey) {
		t.Fatalf("TGDB KEY LEAKED into logs on the failing-echo path:\n%s", out)
	}
	// Non-vacuous on this path too: the echoed output DID reach the logs
	// (via the folded per-pass error), redacted.
	if !strings.Contains(out, "[redacted]") {
		t.Errorf("no [redacted] marker in logged failure tails — redaction not exercised:\n%s", out)
	}
	if !strings.Contains(out, "screenscraper pass failed") || !strings.Contains(out, "thegamesdb pass failed") {
		t.Errorf("expected both credentialed passes' failures in logs:\n%s", out)
	}
}

func TestScrapeSkipsEmptyDir(t *testing.T) {
	h := newHarness(t)

	// Truly empty platform tree: both guards (missing dir, zero ROM files)
	// must skip silently and never exec Skyscraper.
	for _, name := range []string{"Aladdin (USA).nes", "Battle City (USA).zip"} {
		if err := os.Remove(filepath.Join(h.dir, name)); err != nil {
			t.Fatal(err)
		}
	}
	if err := h.driver.ScrapeSystem(hSysKey); err != nil {
		t.Fatalf("empty dir: ScrapeSystem = %v, want nil (idempotent skip)", err)
	}
	if _, err := os.Stat(h.argvPath); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("fake invoked despite empty games dir (capture: %v)", err)
	}

	// A stray dotfile must not falsely pass the ROM count either (the
	// script's $ROM_RE guard against zeroing the shared cache).
	dot := filepath.Join(h.dir, ".gitkeep")
	if err := os.WriteFile(dot, []byte(""), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.ScrapeSystem(hSysKey); err != nil {
		t.Fatalf("dotfile-only dir: ScrapeSystem = %v, want nil", err)
	}
	if _, err := os.Stat(h.argvPath); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("fake invoked despite dotfile-only dir (capture: %v)", err)
	}
}

// TestScrapeGameSingleMode proves a single-game rerun windows ONLY the two
// gather passes (--startat/--endat at relPath); the pegasus compose still
// exports the whole platform, exactly like the script's rerun mode.
func TestScrapeGameSingleMode(t *testing.T) {
	h := newHarness(t)
	rel := "Aladdin (USA).nes"

	if err := h.driver.ScrapeGame(hSysKey, rel); err != nil {
		t.Fatalf("ScrapeGame: %v", err)
	}

	invs := readInvocations(t, h.argvPath)
	if len(invs) != 3 {
		t.Fatalf("captured %d invocations, want 3:\n%q", len(invs), invs)
	}
	for i, pass := range []string{"gather A", "gather B"} {
		wantFlag(t, pass, invs[i], "--startat", rel)
		wantFlag(t, pass, invs[i], "--endat", rel)
	}
	if hasBare(invs[2], "--startat") || hasBare(invs[2], "--endat") {
		t.Errorf("pegasus compose was windowed; it must export the whole platform: %q", invs[2])
	}

	if err := h.driver.ScrapeGame(hSysKey, ""); err == nil {
		t.Error("ScrapeGame with empty relPath = nil, want error")
	}
}

// TestScrapeNotConfigured proves a zero-value Driver refuses to run rather
// than half-working against nil pointers.
func TestScrapeNotConfigured(t *testing.T) {
	var d Driver // BinPath, CacheDir, Store all zero

	err := d.ScrapeSystem(hSysKey)
	if err == nil {
		t.Fatal("zero-value Driver ScrapeSystem = nil, want error")
	}
	if !strings.Contains(err.Error(), "not configured") {
		t.Errorf("err = %v, want it to say the driver is not configured", err)
	}
	if err := d.ScrapeGame(hSysKey, "x.nes"); err == nil {
		t.Error("zero-value Driver ScrapeGame = nil, want error")
	}
}

// TestPostComposeRewritesAbsolutePaths pins the ADV-P5-04 port of
// cartridge-scrape.sh's two post-compose seds against an ABSOLUTE-path
// fixture (what Skyscraper really writes): "<ROM_ROOT>/<sys>/" prefixes on
// top-level file:/assets.* values become relative to the metadata dir;
// whitespace-only intra-description lines are deleted while truly-empty
// separators and indented continuations survive byte-for-byte.
func TestPostComposeRewritesAbsolutePathsAndDropsWhitespace(t *testing.T) {
	h := newHarness(t)
	md := filepath.Join(h.dir, "metadata.pegasus.txt")
	prefix := h.dir + string(filepath.Separator)

	in := "collection: Famicom\n" +
		"launch: jupiter-retroarch -L fceumm_libretro.so \\\"{file.path}\"\n" +
		"\n" + // 0-char separator: SURVIVES
		"game: Aladdin (USA)\n" +
		"file: " + prefix + "Aladdin (USA).nes\n" +
		"assets.box: " + prefix + "media/box2/Aladdin.png\n" +
		"description: Paragraph one.\n" +
		"   \n" + // whitespace-only paragraph separator: DELETED
		"\tParagraph two, indented continuation: SURVIVES verbatim.\n" +
		"game: Battle City (USA)\n" +
		"file: already/relative.nes\n" // no prefix: untouched
	if err := os.WriteFile(md, []byte(in), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := h.driver.postCompose(hSysKey, h.dir); err != nil {
		t.Fatalf("postCompose: %v", err)
	}

	want := "collection: Famicom\n" +
		"launch: jupiter-retroarch -L fceumm_libretro.so \\\"{file.path}\"\n" +
		"\n" +
		"game: Aladdin (USA)\n" +
		"file: Aladdin (USA).nes\n" +
		"assets.box: media/box2/Aladdin.png\n" +
		"description: Paragraph one.\n" +
		"\tParagraph two, indented continuation: SURVIVES verbatim.\n" +
		"game: Battle City (USA)\n" +
		"file: already/relative.nes\n" // trailing newline preserved too
	got, err := os.ReadFile(md)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != want {
		t.Errorf("rewritten metadata:\n%q\nwant:\n%q", string(got), want)
	}
}

// TestPostComposeWarnsWhenUnlaunchable pins the D-P5b deferral warning: a
// compose that leaves the metadata empty or without a launch line logs
// that the collection stays unlaunchable until P6 seeding lands.
func TestPostComposeWarnsWhenUnlaunchable(t *testing.T) {
	var logs bytes.Buffer
	log.SetOutput(&logs)
	log.SetFlags(log.LstdFlags)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })

	for _, tc := range []struct{ name, body string }{
		{"empty-cache zero-byte compose", ""},
		{"launch-less compose", "collection: Famicom\ngame: X\nfile: X.nes\n"},
	} {
		logs.Reset()
		h := newHarness(t)
		if err := os.WriteFile(filepath.Join(h.dir, "metadata.pegasus.txt"), []byte(tc.body), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := h.driver.postCompose(hSysKey, h.dir); err != nil {
			t.Fatalf("%s: postCompose: %v", tc.name, err)
		}
		if !strings.Contains(logs.String(), "unlaunchable until P6 seeding lands") {
			t.Errorf("%s: no unlaunchable warning in logs:\n%s", tc.name, logs.String())
		}
	}

	// A healthy file warns nothing.
	logs.Reset()
	h := newHarness(t)
	if err := os.WriteFile(filepath.Join(h.dir, "metadata.pegasus.txt"),
		[]byte("collection: Famicom\nlaunch: x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := h.driver.postCompose(hSysKey, h.dir); err != nil {
		t.Fatalf("healthy postCompose: %v", err)
	}
	if strings.Contains(logs.String(), "unlaunchable") {
		t.Errorf("healthy metadata warned unlaunchable:\n%s", logs.String())
	}

	// Missing file: tolerated silently-ish (skip note, never an error).
	logs.Reset()
	if err := newHarness(t).driver.postCompose(hSysKey, filepath.Join(t.TempDir(), "nope")); err != nil {
		t.Errorf("missing-metadata postCompose = %v, want nil", err)
	}
}

// waitIdle blocks until the driver's background job releases its slots
// (bounded; a hung job fails the test instead of hanging it).
func waitIdle(t *testing.T, h *harness) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if !h.driver.State().Running {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatal("scrape still running after 5s")
}

// TestScrapeRespectsSharedPipelineLock pins the scrape half of ADV-P5-03:
// with the shared verify+scrape slot held by another runner, StartOne is
// rejected with exactly ErrBusy (the same sentinel the HTTP layer maps to
// 409) BEFORE recording anything — and the claim is released once the
// background batch finishes, so verify can run again.
func TestScrapeRespectsSharedPipelineLock(t *testing.T) {
	h := newHarness(t)
	var lock pipeline.Mutex
	h.driver.Pipeline = &lock

	if !lock.TryAcquire() {
		t.Fatal("could not claim a fresh pipeline lock")
	}

	runsBefore := runsCount(t, h)
	if err := h.driver.StartOne(hSysKey); !errors.Is(err, ErrBusy) {
		t.Fatalf("StartOne while pipeline busy = %v, want ErrBusy", err)
	}
	if got := runsCount(t, h); got != runsBefore {
		t.Errorf("%d run row(s) recorded despite pipeline-busy rejection", got-runsBefore)
	}

	lock.Release()
	if err := h.driver.StartOne(hSysKey); err != nil {
		t.Fatalf("StartOne after release: %v", err)
	}
	waitIdle(t, h)

	// The background goroutine must have released the shared slot.
	if !lock.TryAcquire() {
		t.Error("pipeline slot still held after scrape finished (release leaked)")
		return
	}
	lock.Release()
}

func TestScrapeAndVerifyMutuallyExclusiveOverSharedLock(t *testing.T) {
	h := newHarness(t)
	var lock pipeline.Mutex
	h.driver.Pipeline = &lock

	// A real igir Runner over throwaway roots, sharing the SAME slot.
	root := t.TempDir()
	runner, err := igir.New(igir.Config{
		Binary:        "/bin/true",
		IncomingDir:   filepath.Join(root, "incoming"),
		DATDir:        filepath.Join(root, "dats"),
		CartridgeRoot: filepath.Join(root, "cart"),
		OpticalRoot:   filepath.Join(root, "optical"),
		ModernRoot:    filepath.Join(root, "modern"),
		ReportDir:     filepath.Join(root, "reports"),
	}, h.driver.Store, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	runner.Pipeline = &lock

	// Scrape claims the slot synchronously inside StartOne.
	if err := h.driver.StartOne(hSysKey); err != nil {
		t.Fatalf("StartOne: %v", err)
	}
	if _, err := runner.Verify([]string{hSysKey}); err != igir.ErrBusy {
		t.Errorf("Verify while scrape holds the shared slot = %v, want igir.ErrBusy", err)
	}
	waitIdle(t, h)
	if _, err := runner.Verify([]string{hSysKey}); err != nil {
		t.Errorf("Verify after scrape finished = %v, want nil", err)
	}
}

// runsCount reads the runs table size through the store.
func runsCount(t *testing.T, h *harness) int {
	t.Helper()
	runs, err := h.driver.Store.RecentRuns(100)
	if err != nil {
		t.Fatalf("RecentRuns: %v", err)
	}
	return len(runs)
}
