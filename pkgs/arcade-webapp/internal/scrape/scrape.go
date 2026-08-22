// Package scrape is the Skyscraper runner (gauntlet plan §2): a Go port of
// scripts/cartridge-scrape.sh's per-platform body — resource gather
// (ScreenScraper primary / configured source gap-fill) then the pegasus
// compose, all into the shared resource cache, finishing with the scanner's
// coverage-flag refresh.
//
// Script semantics preserved EXACTLY (the script is the spec):
//
//   - Missing games-tree dir or zero ROM files -> skip (idempotent; the ROM
//     count guards against a stray dotfile zeroing the cache).
//   - Per-pass failures are LOGGED AND CONTINUED, never batch aborts.
//   - Credential FILES are read at call time and their contents are passed
//     straight to the scraper via -u — contents are never logged, never
//     embedded in an error, never persisted anywhere else.
package scrape

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/pipeline"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/scanner"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// passTimeout caps every Skyscraper invocation (each phase, not the batch).
const passTimeout = 30 * time.Minute

// ErrBusy is returned when a scrape is requested while one is running
// (the webapp serializes pipeline jobs — plan R5), mirroring igir.ErrBusy.
var ErrBusy = errors.New("scrape: a scrape is already running")

// Outcome labels for one system's scrape step (the run detail's JSON
// values — same vocabulary as the igir runner's outcomes).
const (
	OutcomeScraped      = "scraped"       // ≥1 pass ok (+ coverage refresh)
	OutcomeSkippedEmpty = "skipped-empty" // no games dir / zero ROM files
	OutcomeFailed       = "failed"        // setup error or every pass failed
)

// defaultRomSuffixes is the ROM-count filter used ONLY when a system's
// catalogue row carries no usable Extensions (ADV-P5-05): real systems
// carry 30+ extensions across the fleet and every row already carries its
// own list, so the per-row set is authoritative and this hardcoded common
// subset is just the fallback (cartridge-scrape.sh's $ROM_RE shape).
var defaultRomSuffixes = []string{
	".zip", ".nes", ".sfc", ".gb", ".gbc", ".gba",
	".n64", ".cue", ".bin", ".chd", ".iso",
}

// globalRomExtras are appended to EVERY row-derived set: No-Intro sets ship
// as zips and cue/bin pairs travel together (the script's GLOBAL_RE extras),
// whatever else the row lists.
var globalRomExtras = []string{".zip", ".bin"}

// romSuffixSet builds one system's allowed ROM-file suffix set (lowercased,
// dotted) from its persisted Extensions JSON (`["nes","zip"]`), unioned
// with the script's global extras. A missing/unparseable/empty list falls
// back to defaultRomSuffixes so an unpopulated row can never widen the
// gate to "any file".
func romSuffixSet(row store.SystemRow) map[string]bool {
	set := map[string]bool{}
	var exts []string
	if err := json.Unmarshal([]byte(row.Extensions), &exts); err == nil {
		for _, e := range exts {
			e = strings.ToLower(strings.TrimSpace(e))
			if e == "" {
				continue
			}
			set["."+strings.TrimPrefix(e, ".")] = true
		}
	}
	if len(set) == 0 {
		set = make(map[string]bool, len(defaultRomSuffixes))
		for _, s := range defaultRomSuffixes {
			set[s] = true
		}
		return set // fallback already includes the global extras
	}
	for _, s := range globalRomExtras {
		set[s] = true
	}
	return set
}

// defaultSource is cartridge-scrape.sh's positional <source> default.
const defaultSource = "thegamesdb"

// Driver anchors scraping at the binaries, trees and credential files it
// needs. Credential fields hold PATHS, never values (read at call time —
// activation-time sops secrets).
//
// The driver also OWNS scrape serialization: one job at a time (mutex-
// guarded State, mirroring igir.Runner), because concurrent Skyscraper
// invocations would race on the same platform db.xml and on the shared
// per-system config ini. Pipeline, when set, is the process-wide heavy-job
// lock shared with the igir runner (ADV-P5-03) — a scrape refuses to start
// while a verify runs and vice versa; nil keeps the driver self-serializing
// only.
type Driver struct {
	BinPath                string // Skyscraper executable ("" = not configured)
	CacheDir               string // Skyscraper resource-cache root
	Source                 string // secondary/fallback scraper ("" = thegamesdb)
	ScreenscraperCredsFile string // optional path to user:password creds
	TGDBKeyFile            string // optional path to TheGamesDB apikey
	Store                  *store.Store
	Pipeline               *pipeline.Mutex // shared verify+scrape slot (optional)
	// Bucket roots: the games tree is <root>/<sys>, routed by the
	// catalogue row's Bucket column (igir's bucketRoot mapping).
	CartridgeRoot string
	OpticalRoot   string
	ModernRoot    string

	mu    sync.Mutex
	state State
}

// State is the in-memory scrape status the UI polls (the runs table is
// the durable record — kind=scrape, one row per batch).
type State struct {
	Running       bool
	StartedAt     string
	CurrentSystem string
	Done, Total   int
	LastOKAt      string
	LastError     string
}

// SystemOutcome is one system's result — the run detail's JSON shape and
// the metadata page's per-system history point. Games/Desc/Cover are the
// post-scrape coverage counts (games rows / has_description / has_cover),
// recorded so run-over-run deltas need no cache re-parse at render time.
type SystemOutcome struct {
	Sys     string `json:"Sys"`
	Outcome string `json:"Outcome"`
	Err     string `json:"Err,omitempty"`
	Games   int64  `json:"Games"`
	Desc    int64  `json:"Desc"`
	Cover   int64  `json:"Cover"`
}

// State returns the current in-memory scrape status.
func (d *Driver) State() State {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.state
}

func (d *Driver) setState(mutate func(*State)) {
	d.mu.Lock()
	defer d.mu.Unlock()
	mutate(&d.state)
}

// Configured reports whether the driver has everything it must have.
func (d *Driver) Configured() bool {
	return d.BinPath != "" && d.CacheDir != "" && d.Store != nil
}

func (d *Driver) bucketRoot(bucket string) string {
	switch bucket {
	case "optical":
		return d.OpticalRoot
	case "modern":
		return d.ModernRoot
	default:
		return d.CartridgeRoot
	}
}

// ScrapeSystem runs the full three-pass flow for one system. Skips
// (missing dir / no ROMs) are nil errors, like the script — use StartOne
// when the scraped-vs-skipped distinction matters.
func (d *Driver) ScrapeSystem(systemKey string) error {
	oc, err := d.scrapeOutcome(systemKey, "")
	if oc != OutcomeFailed {
		return nil
	}
	return err
}

// ScrapeGame runs the same flow restricted to one ROM (--startat/--endat on
// the gather passes; the pegasus compose still exports the whole platform,
// exactly like a single-game rerun of the script).
func (d *Driver) ScrapeGame(systemKey, relPath string) error {
	if relPath == "" {
		return errors.New("scrape: empty game path")
	}
	oc, err := d.scrapeOutcome(systemKey, relPath)
	if oc != OutcomeFailed {
		return nil
	}
	return err
}

// ---- serialized execution (P5 web control) ---------------------------------

// StartBatch claims the driver's single scrape slot SYNCHRONOUSLY (so a
// second concurrent request gets ErrBusy back before anything spawns —
// the HTTP layer surfaces that as 409) and then scrapes the named systems
// in order in the background, recording one kind=scrape run row for the
// batch. Per-system failures become failed outcomes, never an abort.
func (d *Driver) StartBatch(systemKeys []string) error {
	return d.start(len(systemKeys), func(runID int64, record func(SystemOutcome)) {
		for _, key := range systemKeys {
			d.setState(func(s *State) { s.CurrentSystem = key })
			record(d.scrapeAndCount(key, ""))
			d.setState(func(s *State) { s.Done++ })
		}
	})
}

// StartOne is StartBatch for a single system.
func (d *Driver) StartOne(systemKey string) error {
	return d.StartBatch([]string{systemKey})
}

// StartAll scrapes every catalogue system whose games tree holds ROM
// files ("Scrape all" on the metadata page), in catalogue order. Empty
// trees are filtered here so a batch records real work, not a wall of
// skipped-empty outcomes; a tree emptied between filter and run still
// skips idempotently.
func (d *Driver) StartAll() error {
	systems, err := d.Store.Systems()
	if err != nil {
		return fmt.Errorf("scrape: systems: %w", err)
	}
	keys := make([]string, 0, len(systems))
	for _, sys := range systems {
		dir := filepath.Join(d.bucketRoot(sys.Bucket), sys.Key)
		if fi, serr := os.Stat(dir); serr == nil && fi.IsDir() && romCount(dir, romSuffixSet(sys)) > 0 {
			keys = append(keys, sys.Key)
		}
	}
	return d.StartBatch(keys)
}

// StartGame runs one ROM's re-scrape through the same serialized slot.
func (d *Driver) StartGame(systemKey, relPath string) error {
	if relPath == "" {
		return errors.New("scrape: empty game path")
	}
	return d.start(1, func(_ int64, record func(SystemOutcome)) {
		d.setState(func(s *State) { s.CurrentSystem = systemKey })
		record(d.scrapeAndCount(systemKey, relPath))
	})
}

// start claims the busy slot, opens the run row and launches job in the
// background. The claim is deliberately synchronous: callers can reject
// double-submits deterministically instead of racing goroutine starts.
// When Pipeline is set it is claimed here too (ADV-P5-03) and released
// when the background job finishes — a verify holding the shared slot
// rejects this scrape with ErrBusy, keeping HTTP surfacing (409) identical.
func (d *Driver) start(total int, job func(runID int64, record func(SystemOutcome))) error {
	if !d.Configured() {
		return errors.New("scrape: driver not configured")
	}
	d.mu.Lock()
	if d.state.Running {
		d.mu.Unlock()
		return ErrBusy
	}
	d.state = State{Running: true, StartedAt: time.Now().UTC().Format(time.RFC3339), Total: total}
	d.mu.Unlock()

	if d.Pipeline != nil && !d.Pipeline.TryAcquire() {
		// A verify (or another scrape via a second driver instance)
		// holds the pipeline; surface the same busy contract as our own
		// slot so callers cannot tell the two locks apart.
		d.setState(func(s *State) { s.Running = false })
		return ErrBusy
	}
	release := func() {
		if d.Pipeline != nil {
			d.Pipeline.Release()
		}
	}

	runID, err := d.Store.StartRun("scrape")
	if err != nil {
		d.setState(func(s *State) { s.Running = false })
		release()
		return fmt.Errorf("scrape: record run: %w", err)
	}
	go func() {
		defer release()
		defer d.setState(func(s *State) { s.Running = false; s.CurrentSystem = "" })

		outcomes := make([]SystemOutcome, 0, total)
		job(runID, func(oc SystemOutcome) { outcomes = append(outcomes, oc) })

		status := "ok"
		failed := 0
		for _, oc := range outcomes {
			if oc.Outcome == OutcomeFailed {
				failed++
				status = "error"
			}
		}
		detail, _ := json.Marshal(struct {
			Systems []SystemOutcome `json:"Systems"`
		}{Systems: outcomes})
		if err := d.Store.FinishRun(runID, status, string(detail)); err != nil {
			logf("finish run: %v", err)
		}
		d.setState(func(s *State) {
			if status == "ok" {
				s.LastOKAt = time.Now().UTC().Format(time.RFC3339)
				s.LastError = ""
			} else {
				s.LastError = fmt.Sprintf("%d failed system(s)", failed)
			}
		})
	}()
	return nil
}

// scrapeAndCount scrapes one system and folds the post-scrape coverage
// counts into its outcome — the history drill-down's delta data, recorded
// once per run instead of re-derived from caches at render time.
func (d *Driver) scrapeAndCount(systemKey, relPath string) SystemOutcome {
	out := SystemOutcome{Sys: systemKey}
	oc, serr := d.scrapeOutcome(systemKey, relPath)
	out.Outcome = oc
	if serr != nil {
		out.Err = serr.Error()
		logf("%s: %v", systemKey, serr)
	} else if oc == OutcomeScraped {
		logf("%s: scraped ok", systemKey)
	}
	if games, desc, cover, cerr := d.Store.SystemScrapeCounts(systemKey); cerr == nil {
		out.Games, out.Desc, out.Cover = games, desc, cover
	}
	return out
}

// scrapeOutcome runs cartridge-scrape.sh's three-pass body for one system
// and classifies the result: scraped (≥1 pass ok), skipped-empty (the
// script's idempotent guards) or failed (setup error or EVERY pass
// failed — per-pass failures are still logged-and-continued, never an
// abort; a batch where nothing succeeded is reported, not swallowed).
func (d *Driver) scrapeOutcome(systemKey, startAt string) (string, error) {
	if !d.Configured() {
		return OutcomeFailed, errors.New("scrape: driver not configured")
	}
	sys, err := d.lookupSystem(systemKey)
	if err != nil {
		return OutcomeFailed, err
	}
	dir := filepath.Join(d.bucketRoot(sys.Bucket), sys.Key)

	// Idempotent skips (the script's first two guards).
	if fi, serr := os.Stat(dir); serr != nil || !fi.IsDir() {
		logf("%s: games dir missing (%s); skipping", systemKey, dir)
		return OutcomeSkippedEmpty, nil
	}
	if romCount(dir, romSuffixSet(sys)) == 0 {
		logf("%s: no ROM files in %s; skipping to protect Skyscraper cache", systemKey, dir)
		return OutcomeSkippedEmpty, nil
	}

	// Launch line: retroarch+core wins, else the dedicated emulator, else
	// there is nothing playable to seed — refuse loudly.
	var launch string
	switch {
	case sys.Core != "" && sys.Core != "-":
		launch = "jupiter-retroarch -L " + sys.Core
	case sys.Emulator != "":
		launch = "jupiter-" + sys.Emulator
	default:
		return OutcomeFailed, fmt.Errorf("scrape: %s: no core or emulator mapped; cannot build launch line", systemKey)
	}

	skyPlatform := sys.Key
	if sys.SkyHandle != "" {
		skyPlatform = sys.SkyHandle
	}
	// The cache dir is keyed on the CATALOGUE KEY, exactly like
	// cartridge-scrape.sh ($platform_cache="$CACHE_DIR/$platform" where
	// $platform is our key): only -p receives Skyscraper's handle. Keying
	// -d on the handle instead made every diverging system (ps1→psx,
	// gamecube→gc, pokemonmini→pokemini, dsi→nds, …) miss its live europa
	// cache — quota burn — and collided new3ds/3ds on the shared "3ds"
	// handle (ADV-P5-01).
	cache := filepath.Join(d.CacheDir, systemKey)
	if err := os.MkdirAll(cache, 0o755); err != nil {
		return OutcomeFailed, fmt.Errorf("scrape: %s: cache dir: %w", systemKey, err)
	}

	// Per-system Skyscraper config. The [pegasus] launch line becomes the
	// collection's `launch:` field in metadata.pegasus.txt. {file.path} is
	// the Pegasus token for the ROM's path, wrapped in BACKSLASH-escaped
	// quotes (literal \" bytes in the file): Qt's INI parser strips a bare
	// quote pair, which would leave the token unquoted and word-split
	// No-Intro paths at launch time — see cartridge-scrape.sh.
	iniPath := filepath.Join(d.CacheDir, "config-"+systemKey+".ini")
	ini := fmt.Sprintf("[pegasus]\nlaunch=%s \\\"{file.path}\"\n", launch)
	if err := os.WriteFile(iniPath, []byte(ini), 0o644); err != nil {
		return OutcomeFailed, fmt.Errorf("scrape: %s: write config: %w", systemKey, err)
	}

	source := d.Source
	if source == "" {
		source = defaultSource
	}

	anyOK := false
	attempted := 0
	haveSS := false
	sec := &secrets{} // every credential read below is registered for redaction

	// Pass A: ScreenScraper primary — CRC-exact for zips via unpack, -t 1
	// for the free-tier thread cap. Only when the creds FILE is readable.
	if creds, cerr := readCreds(d.ScreenscraperCredsFile); cerr == nil {
		haveSS = true
		sec.add(creds)
		args := []string{
			"-p", skyPlatform,
			"-s", "screenscraper",
			"-i", dir,
			"-d", cache,
			"-c", iniPath,
			"-u", creds, // contents: exec argv only, never logged unredacted
			"-t", "1",
			"--flags", "unattend,unpack",
		}
		args = addWindow(args, startAt)
		attempted++
		if err := d.runPass(systemKey, "screenscraper", args, sec); err != nil {
			logf("%s: %v (continuing)", systemKey, err)
		} else {
			anyOK = true
		}
	}

	// Pass B: configured source — onlymissing gap-fill when ScreenScraper
	// ran (a fuzzy filename match must not overwrite a checksum match),
	// full scrape as primary otherwise. TheGamesDB benefits from -u.
	flags := "unattend"
	if haveSS {
		flags = "unattend,onlymissing"
	}
	args := []string{
		"-p", skyPlatform,
		"-s", source,
		"-i", dir,
		"-d", cache,
		"-c", iniPath,
	}
	if source == defaultSource {
		if key, cerr := readCreds(d.TGDBKeyFile); cerr == nil {
			sec.add(key)
			args = append(args, "-u", key)
		}
	}
	args = append(args, "--flags", flags)
	args = addWindow(args, startAt)
	attempted++
	if err := d.runPass(systemKey, source, args, sec); err != nil {
		logf("%s: %v (continuing)", systemKey, err)
	} else {
		anyOK = true
	}

	// Pass C: compose Pegasus frontend files from the cache. -d MUST point
	// at the same cache the gather passes wrote (otherwise Skyscraper
	// reads its empty default and emits zero entries); -g drops the
	// metadata next to the ROMs.
	args = []string{
		"-p", skyPlatform,
		"-f", "pegasus",
		"-i", dir,
		"-d", cache,
		"-g", dir,
		"-c", iniPath,
		"--flags", "unattend",
	}
	attempted++
	pegasusOK := false
	if err := d.runPass(systemKey, "pegasus", args, sec); err != nil {
		logf("%s: %v (continuing)", systemKey, err)
	} else {
		anyOK = true
		pegasusOK = true
	}

	// Post-compose fixes after a compose that wrote metadata (ADV-P5-04):
	// the absolute→relative path rewrite and the whitespace-only-line
	// deletion. seed_launchable_metadata + split_pending stay DEFERRED to
	// P6, which owns metadata generation (D-P5b) — postCompose warns when
	// a collection is left unlaunchable in the meantime.
	if pegasusOK {
		if err := d.postCompose(systemKey, dir); err != nil {
			logf("%s: post-compose: %v", systemKey, err)
		}
	}

	if !anyOK {
		return OutcomeFailed, fmt.Errorf("scrape: %s: all %d pass(es) failed", systemKey, attempted)
	}

	// Coverage refresh after ANY successful pass — best effort; a scanner
	// hiccup must not fail an otherwise-successful scrape.
	if err := scanner.ApplyCacheFlags(d.Store, sys, dir, cache); err != nil {
		logf("%s: coverage refresh: %v", systemKey, err)
	}
	return OutcomeScraped, nil
}

// lookupSystem resolves one catalogue row (Systems() is the store's only
// reader; igir maps by key the same way).
func (d *Driver) lookupSystem(systemKey string) (store.SystemRow, error) {
	systems, err := d.Store.Systems()
	if err != nil {
		return store.SystemRow{}, fmt.Errorf("scrape: systems: %w", err)
	}
	for _, s := range systems {
		if s.Key == systemKey {
			return s, nil
		}
	}
	return store.SystemRow{}, fmt.Errorf("scrape: unknown system %q (not in catalogue)", systemKey)
}

// readCreds reads a credential FILE at call time and trims it the way the
// script's $(cat …) did. Errors carry the path only — contents never reach
// a log or an error.
func readCreds(path string) (string, error) {
	if path == "" {
		return "", errors.New("no credentials file configured")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("credentials file %s unreadable: %w", path, err)
	}
	return strings.TrimSpace(string(b)), nil
}

// secrets carries the credential VALUES read for one scrape run (ADV-P5-
// 02): Skyscraper echoes its own argv in failure output and Qt network
// errors embed URLs carrying ssid/sspassword, so any child-output tail
// folded into an error or a log line can carry live credentials. apply is
// the SINGLE choke point every such tail passes through before it enters
// an error or a log — each known value becomes [redacted].
type secrets struct{ vals []string }

func (s *secrets) add(v string) {
	if v != "" {
		s.vals = append(s.vals, v)
	}
}

func (s *secrets) apply(out string) string {
	for _, v := range s.vals {
		out = strings.ReplaceAll(out, v, "[redacted]")
	}
	return out
}

// addWindow restricts a gather pass to one ROM (--startat/--endat).
func addWindow(args []string, startAt string) []string {
	if startAt == "" {
		return args
	}
	return append(args, "--startat", startAt, "--endat", startAt)
}

// postCompose applies cartridge-scrape.sh's two post-compose seds to
// <dir>/metadata.pegasus.txt (ADV-P5-04), then checks launchability:
//
//   - absolute→relative rewrite — strip the "<ROM_ROOT>/<sys>/" prefix
//     from the values of top-level "file:" and "assets.<key>:" entries.
//     The kiosks mount the tree at /mnt/europa-cartridges, not /tank/…,
//     so Skyscraper's absolute paths would make Pegasus drop every game
//     and asset there; relative paths resolve against the collection root
//     on whichever host mounts the tree (no Skyscraper option exists for
//     this on the pegasus frontend).
//   - whitespace-only-line deletion — Skyscraper emits intra-description
//     paragraph separators of bare spaces/tabs; Pegasus treats them as
//     entry-ending blank lines and rejects the next indented continuation.
//     Truly-empty (0-char) separators survive.
//
// seed_launchable_metadata + split_pending are deliberately NOT ported
// here — P6 owns metadata generation and inherits them (D-P5b). Until it
// lands, an empty or launch-less file is reported as a warning: the
// collection stays unlaunchable rather than silently broken.
func (d *Driver) postCompose(systemKey, dir string) error {
	md := filepath.Join(dir, "metadata.pegasus.txt")
	b, err := os.ReadFile(md)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			logf("%s: no post-compose metadata at %s; skipping post-steps", systemKey, md)
			return nil
		}
		return err
	}

	prefix := dir + string(filepath.Separator) // "<ROM_ROOT>/<sys>/"
	lines := strings.Split(string(b), "\n")
	out := make([]string, 0, len(lines))
	hasLaunch := false
	for _, line := range lines {
		// Whitespace-only lines are DELETED; truly-empty ones survive
		// (the script's /^[[:space:]][[:space:]]*$/d).
		if line != "" && strings.TrimSpace(line) == "" {
			continue
		}
		line = rewriteRelPathLine(line, prefix)
		if strings.HasPrefix(line, "launch: ") {
			hasLaunch = true
		}
		out = append(out, line)
	}
	if err := os.WriteFile(md, []byte(strings.Join(out, "\n")), 0o644); err != nil {
		return fmt.Errorf("rewrite %s: %w", md, err)
	}

	if len(out) == 0 || !hasLaunch {
		logf("%s: post-compose metadata is empty or lacks a launch line — collection unlaunchable until P6 seeding lands", systemKey)
	}
	return nil
}

// rewriteRelPathLine strips an absolute "<ROM_ROOT>/<sys>/" prefix from
// one metadata line's value when the line opens a top-level "file:" or
// "assets.<key>:" entry — the Go equivalent of cartridge-scrape.sh's two
// sed substitutions. Indented continuation lines never match (they don't
// start with the entry keys) and pass through untouched.
func rewriteRelPathLine(line, absPrefix string) string {
	switch {
	case strings.HasPrefix(line, "file: "):
		return "file: " + strings.TrimPrefix(line[len("file: "):], absPrefix)
	case strings.HasPrefix(line, "assets."):
		i := strings.Index(line, ": ")
		if i >= 0 {
			return line[:i+2] + strings.TrimPrefix(line[i+2:], absPrefix)
		}
	}
	return line
}

// runPass execs BinPath with the given args, mirroring runner.go: combined
// output is folded (tail-first) into the returned error, never dumped raw.
// The tail passes through sec.apply FIRST (ADV-P5-02): a failing
// Skyscraper echoes its own argv and Qt network errors embed URLs carrying
// credentials, so no child output reaches an error or a log unredacted.
func (d *Driver) runPass(systemKey, name string, args []string, sec *secrets) error {
	ctx, cancel := context.WithTimeout(context.Background(), passTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, d.BinPath, args...)
	// Skyscraper is Qt6; a headless service cannot construct a platform
	// surface without offscreen (cartridge-scrape.sh's unit environment).
	cmd.Env = append(os.Environ(), "QT_QPA_PLATFORM=offscreen")
	out, err := cmd.CombinedOutput()
	tail := strings.TrimSpace(sec.apply(string(out))) // THE redaction choke point
	if len(tail) > 400 {
		tail = "…" + tail[len(tail)-400:]
	}
	if err != nil {
		return fmt.Errorf("%s pass failed (%v): %s", name, err, tail)
	}
	logf("%s: %s pass ok", systemKey, name)
	return nil
}

// romCount counts regular files whose suffix is in the system's allowed
// set anywhere below dir — counting ACTUAL ROM files, not "any file" (a
// stray .gitkeep must not falsely pass; recursive so nested layouts count
// too, like the script's find).
func romCount(dir string, allowed map[string]bool) int {
	count := 0
	_ = filepath.WalkDir(dir, func(_ string, entry fs.DirEntry, err error) error {
		if err != nil {
			return nil // unreadable entries read as absent, like find's
		}
		if entry.IsDir() || !entry.Type().IsRegular() {
			return nil
		}
		ext := strings.ToLower(filepath.Ext(entry.Name()))
		if allowed[ext] {
			count++
		}
		return nil
	})
	return count
}

func logf(format string, args ...any) {
	log.Printf("scrape: "+format, args...)
}
