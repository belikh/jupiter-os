// Package igir is the verify runner (gauntlet P3, goal 3): a line-by-line
// Go port of scripts/cartridge-verify.sh — igir hashes each staged set
// against its No-Intro DAT and COPIES the DAT-matched, checksum-valid
// ROMs into the curated games tree, writing the audit CSV the webapp
// ingests.
//
// Script semantics preserved EXACTLY (the script is the spec until P8
// retires it):
//
//   - COPY, never move/link/quarantine: the staged tree IS the aria2
//     torrent download; moving verified ROMs out of it breaks the
//     daemon's piece state. The games tree is a pure curated view.
//   - Nothing staged under <incoming>/<sys> -> skip (idempotent).
//   - Any *.aria2 control file under the staged tree -> SKIP entirely:
//     the download is mid-flight and partial files cannot DAT-match.
//   - No <datDir>/<sys>.dat -> warn, skip verification, copy everything
//     staged straight to the bucket tree (better partial than blocked;
//     recorded as an "unchecked" promote — grey, not red).
//   - Otherwise: igir `copy test report` with the script's flag set
//     (--input-checksum-max CRC32, --dir-game-subdir never, thread pins)
//     plus one deliberate addition — an input-anchored
//     --input-exclude <input>/**/*.torrent (aria2's infohash metadata
//     companions; see runIgir) — and a non-zero igir exit is a WARNING,
//     never a batch abort.
//   - Bucket routing cartridge/optical/modern comes from the catalogue
//     row (the systems table).
package igir

import (
	"context"
	"encoding/csv"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// ErrBusy is returned when a verify is requested while one is running
// (the webapp serializes pipeline jobs — plan R5).
var ErrBusy = errors.New("igir: a verify is already running")

// Config anchors the runner at the trees it reads and writes.
type Config struct {
	Binary string // igir executable path ("" = not configured)
	// IncomingDir is the aria2 staging root: one <sys>/ subdir per system.
	IncomingDir string
	// DATDir holds one <sys>.dat per system.
	DATDir string
	// Bucket roots: igir's --output is <root>/<sys>, routed by the
	// catalogue bucket column (rom-acquire's bucketDir mapping).
	CartridgeRoot string
	OpticalRoot   string
	ModernRoot    string
	// ReportDir is where the audit CSVs land (<dir>/<sys>.csv) —
	// cartridge-verify.sh's <scratch>/reports.
	ReportDir string
}

func (c Config) bucketRoot(bucket string) string {
	switch bucket {
	case "optical":
		return c.OpticalRoot
	case "modern":
		return c.ModernRoot
	default:
		return c.CartridgeRoot
	}
}

// Configured reports whether the runner has its binary.
func (c Config) Configured() bool { return c.Binary != "" }

// State is the in-memory verify status the UI polls (the runs table is
// the durable record).
type State struct {
	Running       bool
	StartedAt     string
	CurrentSystem string
	Done, Total   int
	LastOKAt      string
	LastError     string
}

// Outcome labels for one system's verify step.
const (
	OutcomeVerified           = "verified"            // igir ran; report ingested
	OutcomeSkippedEmpty       = "skipped-empty"       // nothing staged (idempotent skip)
	OutcomeSkippedDownloading = "skipped-downloading" // .aria2 control files present
	OutcomePromotedUnchecked  = "promoted-unchecked"  // no DAT: copied as-is
	OutcomeFailed             = "failed"              // igir/report error
)

// SystemOutcome is one system's result — the run detail's JSON shape and
// the verify page's per-system summary.
type SystemOutcome struct {
	Sys     string `json:"Sys"`
	Outcome string `json:"Outcome"`
	Err     string `json:"Err,omitempty"`
	// Report counts (provenance-split — see Report).
	DatGames      int    `json:"DatGames"`
	Found         int    `json:"Found"`
	Missing       int    `json:"Missing"`
	Unmatched     int    `json:"Unmatched"` // input-side deviations (red)
	Duplicate     int    `json:"Duplicate"` // output-side re-verify echoes (benign)
	Extra         int    `json:"Extra"`     // output-side files the DAT doesn't claim (amber)
	Other         int    `json:"Other"`
	PromotedBytes int64  `json:"PromotedBytes"`
	CopiedFiles   int    `json:"CopiedFiles"` // unchecked-promote path
	ReportPath    string `json:"ReportPath,omitempty"`
}

// Runner owns verify execution and serialization.
type Runner struct {
	cfg Config
	st  *store.Store
	// rescan, when set, runs after a batch that promoted anything (the
	// games table must learn about newly promoted files; the scanner
	// preserves verify_state, so this is safe to run any time).
	rescan func() error
	log    *log.Logger

	mu    sync.Mutex
	state State
}

// New builds a Runner. rescan may be nil.
//
// Every path field except Binary must be an ABSOLUTE path (empty
// included in the rejection: filepath.Join("", sys) yields a bare
// relative key): igir resolves relative path arguments — and expands
// the input-anchored --input-exclude glob — against its process cwd,
// so a relative root silently re-arms exactly the cwd-rooted crawl the
// anchored exclude exists to prevent (D-P3e, the run-2/5 VM hang that
// walked the whole nix store). The NixOS module always passes absolute
// paths; this guard exists for hand-rolled envs and fails construction
// loudly instead of hanging minutes later (ADV-P3-03).
func New(cfg Config, st *store.Store, rescan func() error, lg *log.Logger) (*Runner, error) {
	for _, f := range []struct{ field, path string }{
		{"IncomingDir", cfg.IncomingDir},
		{"DATDir", cfg.DATDir},
		{"CartridgeRoot", cfg.CartridgeRoot},
		{"OpticalRoot", cfg.OpticalRoot},
		{"ModernRoot", cfg.ModernRoot},
		{"ReportDir", cfg.ReportDir},
	} {
		if f.path == "" || !filepath.IsAbs(f.path) {
			return nil, fmt.Errorf("igir: Config.%s must be an absolute path, got %q (relative roots re-arm igir's cwd-rooted glob expansion)", f.field, f.path)
		}
	}
	return &Runner{cfg: cfg, st: st, rescan: rescan, log: lg}, nil
}

// State returns the current in-memory verify status.
func (r *Runner) State() State {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.state
}

func (r *Runner) setState(mutate func(*State)) {
	r.mu.Lock()
	defer r.mu.Unlock()
	mutate(&r.state)
}

// Configured reports whether the igir binary is wired.
func (r *Runner) Configured() bool { return r.cfg.Configured() }

// ReportDir exposes the audit-CSV directory (the web layer serves
// per-system reports from exactly this dir).
func (r *Runner) ReportDir() string { return r.cfg.ReportDir }

// VerifyAll verifies every catalogue system, in catalogue order.
func (r *Runner) VerifyAll() ([]SystemOutcome, error) {
	systems, err := r.st.Systems()
	if err != nil {
		return nil, fmt.Errorf("igir: systems: %w", err)
	}
	keys := make([]string, len(systems))
	for i, s := range systems {
		keys[i] = s.Key
	}
	return r.Verify(keys)
}

// Verify runs the cartridge-verify.sh flow for the named systems, in the
// order given. One 'verify' run row records the whole batch; per-system
// failures become failed outcomes (the script's subshell-per-system
// isolation), never a batch abort.
func (r *Runner) Verify(systemKeys []string) ([]SystemOutcome, error) {
	r.mu.Lock()
	if r.state.Running {
		r.mu.Unlock()
		return nil, ErrBusy
	}
	r.state = State{Running: true, StartedAt: time.Now().UTC().Format(time.RFC3339), Total: len(systemKeys)}
	r.mu.Unlock()
	defer r.setState(func(s *State) { s.Running = false; s.CurrentSystem = "" })

	byKey := map[string]store.SystemRow{}
	systems, err := r.st.Systems()
	if err != nil {
		return nil, fmt.Errorf("igir: systems: %w", err)
	}
	for _, s := range systems {
		byKey[s.Key] = s
	}

	runID, err := r.st.StartRun("verify")
	if err != nil {
		return nil, fmt.Errorf("igir: record run: %w", err)
	}

	outcomes := make([]SystemOutcome, 0, len(systemKeys))
	promoted := false
	for _, key := range systemKeys {
		r.setState(func(s *State) { s.CurrentSystem = key })
		sys, ok := byKey[key]
		var oc SystemOutcome
		if !ok {
			oc = SystemOutcome{Sys: key, Outcome: OutcomeFailed, Err: "unknown system (not in catalogue)"}
		} else {
			oc = r.processSystem(sys, runID)
		}
		if oc.Outcome == OutcomeVerified || oc.Outcome == OutcomePromotedUnchecked {
			promoted = true
		}
		outcomes = append(outcomes, oc)
		r.setState(func(s *State) { s.Done++ })
	}

	status := "ok"
	for _, oc := range outcomes {
		if oc.Outcome == OutcomeFailed {
			status = "error"
		}
	}
	detail, _ := json.Marshal(struct {
		Systems  []SystemOutcome `json:"Systems"`
		Promoted bool            `json:"Promoted"`
	}{Systems: outcomes, Promoted: promoted})
	if err := r.st.FinishRun(runID, status, string(detail)); err != nil {
		r.logf("finish run: %v", err)
	}

	r.setState(func(s *State) {
		if status == "ok" {
			s.LastOKAt = time.Now().UTC().Format(time.RFC3339)
		} else {
			s.LastError = fmt.Sprintf("%d failed systems", len(systemKeys))
		}
	})

	// Newly promoted files are invisible to the dashboard until the next
	// scan — kick one now (best effort; a concurrent scan just wins).
	if promoted && r.rescan != nil {
		if err := r.rescan(); err != nil && !errors.Is(err, ErrBusy) && !strings.Contains(err.Error(), "already running") {
			r.logf("post-verify rescan: %v", err)
		}
	}
	return outcomes, nil
}

// processSystem is cartridge-verify.sh's process_system, ported. runID
// ties the recorded verify_results row back to its runs-table entry.
func (r *Runner) processSystem(sys store.SystemRow, runID int64) SystemOutcome {
	oc := SystemOutcome{Sys: sys.Key}
	incoming := filepath.Join(r.cfg.IncomingDir, sys.Key)
	dat := filepath.Join(r.cfg.DATDir, sys.Key+".dat")
	output := filepath.Join(r.cfg.bucketRoot(sys.Bucket), sys.Key)
	report := filepath.Join(r.cfg.ReportDir, sys.Key+".csv")

	// Nothing staged -> skip (idempotent; the script's first guard).
	if !dirHasFiles(incoming) {
		oc.Outcome = OutcomeSkippedEmpty
		return oc
	}

	// Still downloading? The .aria2 control files are aria2's resume
	// state, and the partial files cannot DAT-match — verifying now
	// would flood the games tree with junk.
	if hasAria2Control(incoming) {
		oc.Outcome = OutcomeSkippedDownloading
		return oc
	}

	if _, err := os.Stat(dat); errors.Is(err, fs.ErrNotExist) {
		// Missing DAT: skip verification, copy staged ROMs as-is
		// ("better partial than blocked"). rsync -a semantics: files
		// identical in size+mtime are skipped, so re-runs are cheap.
		if err := os.MkdirAll(output, 0o755); err != nil {
			oc.Outcome, oc.Err = OutcomeFailed, err.Error()
			return oc
		}
		bytes, files, err := copyTree(incoming, output)
		if err != nil {
			oc.Outcome, oc.Err = OutcomeFailed, err.Error()
			return oc
		}
		oc.Outcome = OutcomePromotedUnchecked
		oc.PromotedBytes, oc.CopiedFiles = bytes, files
		_ = r.st.RecordVerifyResult(store.VerifyResult{
			SystemKey: sys.Key, RunID: runID, Unchecked: 1,
			PromotedBytes: bytes,
			FinishedAt:    time.Now().UTC().Format(time.RFC3339),
		})
		r.logf("%s: no DAT — promoted %d file(s) unchecked (%d bytes)", sys.Key, files, bytes)
		return oc
	}

	// igir copy test report — cartridge-verify.sh's flag set plus the
	// aria2-metadata exclusion (see runIgir's --input-exclude comment).
	if err := os.MkdirAll(output, 0o755); err != nil {
		oc.Outcome, oc.Err = OutcomeFailed, err.Error()
		return oc
	}
	if err := os.MkdirAll(r.cfg.ReportDir, 0o755); err != nil {
		oc.Outcome, oc.Err = OutcomeFailed, err.Error()
		return oc
	}
	if err := r.runIgir(dat, incoming, output, report); err != nil {
		// Non-zero igir exit is a warning, not an abort (the script's
		// `warn "$sys: igir exited non-zero; see $report"`): the report
		// may still be valid, so parse and record what it says.
		oc.Err = err.Error()
	}

	rep, perr := parseReportFile(report, incoming, output)
	if perr != nil {
		if oc.Err == "" {
			oc.Err = perr.Error()
		} else {
			oc.Err += "; " + perr.Error()
		}
		oc.Outcome = OutcomeFailed
		// Log here: this early return otherwise skips every logf below,
		// and a failed igir (no report) would leave NO journal trace
		// (bitten during P3 VM bring-up — the smoke's journal-tail
		// debug was blind exactly when it was needed).
		errStr := oc.Err
		if len(errStr) > 400 {
			errStr = "…" + errStr[len(errStr)-400:]
		}
		r.logf("%s: failed — %s", sys.Key, errStr)
		return oc
	}
	if oc.Err != "" {
		// igir exited non-zero but its report parsed — record the counts
		// (the run detail carries both the warning and the numbers).
		oc.Outcome = OutcomeFailed
	} else {
		oc.Outcome = OutcomeVerified
	}
	oc.DatGames, oc.Found = rep.DatGames, rep.Found
	oc.Missing, oc.Unmatched = rep.Missing, rep.Unmatched
	oc.Duplicate, oc.Other, oc.Extra = rep.Duplicate, rep.Other, rep.Extra
	oc.ReportPath = report
	oc.PromotedBytes = promotedBytes(rep.FoundPaths)

	// Ingest: verify_results row + per-game state flips. The DAT is
	// authoritative — rows the report's FOUND set does not claim become
	// 'unmatched' (see store.SetSystemVerifyStates).
	_ = r.st.RecordVerifyResult(store.VerifyResult{
		SystemKey: sys.Key, RunID: runID,
		FinishedAt: time.Now().UTC().Format(time.RFC3339),
		DatGames:   rep.DatGames, Found: rep.Found, Missing: rep.Missing,
		Unmatched: rep.Unmatched, Duplicate: rep.Duplicate, Other: rep.Other,
		Extra:         rep.Extra,
		PromotedBytes: oc.PromotedBytes, ReportPath: report,
	})
	if err := r.st.SetSystemVerifyStates(sys.Key, rep.FoundRels); err != nil {
		r.logf("%s: verify states: %v", sys.Key, err)
	}
	r.logf("%s: %s — %d/%d found, %d unmatched, %d missing (report: %s)",
		sys.Key, oc.Outcome, rep.Found, rep.DatGames, rep.Unmatched, rep.Missing, report)
	return oc
}

// runIgir execs the binary with cartridge-verify.sh's flag set plus one
// deliberate addition (see the --input-exclude comment below).
// A fresh-ish environment is handed over (HOME/XDG dirs under the
// report dir) so a node-based igir never tries to write into a
// read-only home.
func (r *Runner) runIgir(dat, input, output, report string) error {
	home := filepath.Join(r.cfg.ReportDir, ".igir-home")
	if err := os.MkdirAll(home, 0o700); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Hour)
	defer cancel()
	// The exclude value MUST be anchored to the absolute input dir:
	// igir expands exclude globs against the FILESYSTEM rooted at the
	// process cwd (proven: a bare **/*.torrent from cwd=/ dies with
	// "EACCES: permission denied, scandir '/root'" as a normal user,
	// and as root it crawls the whole nix store for minutes — exactly
	// the P3 VM hang). The anchored form walks only the staged subtree
	// and still excludes every depth under it.
	inputExclude := filepath.Join(input, "**", "*.torrent")
	cmd := exec.CommandContext(ctx, r.cfg.Binary,
		"copy", "test", "report",
		"--dat", dat,
		"--input", input,
		"--output", output,
		"--report-output", report,
		"--input-checksum-max", "CRC32",
		// The ONE deliberate deviation from cartridge-verify.sh's flag
		// set (D-P3e): aria2 writes an infohash-named .torrent metadata
		// file into every download dir — addTorrent included, proven
		// empirically against the pinned aria2 1.37.0 (its docs claim
		// magnet-only; the code disagrees). Those companions are the
		// daemon's bookkeeping, not staged ROM content, and no DAT can
		// ever claim a .torrent ROM — so excluding them cannot hide a
		// real deviation, while the served report then literally
		// carries zero unmatched rows for them (the pill never lies
		// against its own CSV).
		"--input-exclude", inputExclude,
		"--dir-game-subdir", "never",
		"--reader-threads", "2",
		"--writer-threads", "2",
		"--dat-threads", "1",
	)
	cmd.Env = append(os.Environ(), "HOME="+home, "XDG_CACHE_HOME="+home)
	out, err := cmd.CombinedOutput()
	if err != nil {
		tail := string(out)
		if len(tail) > 400 {
			tail = "…" + tail[len(tail)-400:]
		}
		return fmt.Errorf("igir exited non-zero (%v): %s", err, strings.TrimSpace(tail))
	}
	return nil
}

// ---- report ingestion -----------------------------------------------------

// Report is the ingested shape of one igir report CSV: per-status counts
// split by PROVENANCE (which side of the copy a row's file lives on —
// proven by running the real igir 5.3.0 over the fixture corpus with a
// pre-populated output tree, P3 VM bring-up), plus the FOUND rows'
// output-relative paths (the games-table rel_paths the verify-state flips
// key on).
//
// igir scans BOTH the --input dir and the --output dir, so a bare status
// count cannot tell "junk arrived in staging" from "the games tree
// already holds this/extra files":
//
//   - UNUSED row under input  -> Unmatched: staged file no DAT claims
//     (the red signal — the pipeline is receiving junk);
//   - UNUSED row under output -> Extra: a games-tree file the DAT does
//     not claim (operator drops, scanner fixtures; amber, not red — the
//     DAT games may all be present);
//   - DUPLICATE row under input -> Unmatched: two staged files claim one
//     DAT game (the staged set deviates from 1G1R);
//   - DUPLICATE row under output -> Duplicate: the idempotent re-verify
//     echo — input ROMs already promoted in a previous run are re-seen
//     in the output. COPY semantics keep the staged input (aria2's piece
//     state), so EVERY re-verify after the first promotion emits these;
//     counting them red would flip every green system red on its second
//     run. Informational only;
//   - FOUND rows are game-attributed and point into the output dir;
//   - anything else (or a row on neither side) -> Other, red, counted —
//     never silently dropped.
type Report struct {
	DatGames   int // Found + Missing (games the DAT claims)
	Found      int // matched + written + checksum-retested
	Missing    int // DAT games no staged input matched
	Unmatched  int // INPUT-side deviations: UNUSED + DUPLICATE (red)
	Duplicate  int // OUTPUT-side re-verify echoes (benign, informational)
	Extra      int // OUTPUT-side files no DAT claims (amber)
	Other      int // unknown statuses / unknown provenance (red)
	FoundPaths []string
	FoundRels  []string // FoundPaths relative to the igir --output dir
}

// parseReportFile reads + parses the CSV at path.
func parseReportFile(path, inputDir, outputDir string) (*Report, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("igir: report: %w", err)
	}
	defer f.Close() //nolint:errcheck // read-only
	return ParseReport(f, inputDir, outputDir)
}

// ParseReport ingests an igir report CSV. Field semantics proven by
// scripts/fixture-arcade.sh and real 5.3.0 runs: the Status column carries
// FOUND/UNUSED/MISSING/DUPLICATE, and ROM Files (the FOUND rows' output
// paths) is how matched games map back to games-tree rows. The header's
// column INDEX drives parsing (igir has grown columns across versions);
// rows with an empty Status are skipped (the gate's `$3!=""` guard);
// unknown statuses count as Other so nothing silently vanishes. RFC 4180
// parsing keeps comma-free fixture reports identical while surviving
// quoted commas in real DAT names.
func ParseReport(rd io.Reader, inputDir, outputDir string) (*Report, error) {
	cr := csv.NewReader(rd)
	cr.FieldsPerRecord = -1 // tolerate ragged rows; we index defensively
	cr.ReuseRecord = false
	header, err := cr.Read()
	if err != nil {
		return nil, fmt.Errorf("igir: report header: %w", err)
	}
	col := func(name string) int {
		for i, h := range header {
			if strings.TrimSpace(h) == name {
				return i
			}
		}
		return -1
	}
	statusIdx := col("Status")
	if statusIdx < 0 {
		return nil, fmt.Errorf("igir: report has no Status column (header: %v)", header)
	}
	gameIdx := col("Game Name")
	romIdx := col("ROM Files")

	underDir := func(dir, path string) bool {
		if dir == "" || path == "" {
			return false
		}
		rel, err := filepath.Rel(dir, path)
		return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
	}

	rep := &Report{}
	for {
		row, err := cr.Read()
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return nil, fmt.Errorf("igir: report row: %w", err)
		}
		if len(row) <= statusIdx {
			continue // ragged row: skip, do not abort ingestion
		}
		status := strings.ToUpper(strings.TrimSpace(row[statusIdx]))
		if status == "" {
			continue // the gate's empty-status guard
		}
		romPath := ""
		if romIdx >= 0 && romIdx < len(row) {
			romPath = strings.TrimSpace(row[romIdx])
		}
		_ = gameIdx // Game Name kept for future drill-downs (P4)
		switch status {
		case "FOUND":
			rep.Found++
			if romPath != "" {
				rep.FoundPaths = append(rep.FoundPaths, romPath)
				if outputDir != "" {
					if rel, err := filepath.Rel(outputDir, romPath); err == nil && !strings.HasPrefix(rel, "..") {
						rep.FoundRels = append(rep.FoundRels, rel)
					} else {
						rep.FoundRels = append(rep.FoundRels, filepath.Base(romPath))
					}
				}
			}
		case "MISSING":
			rep.Missing++
		case "UNUSED":
			switch {
			case underDir(inputDir, romPath):
				rep.Unmatched++
			case underDir(outputDir, romPath):
				rep.Extra++
			default:
				rep.Other++
			}
		case "DUPLICATE":
			switch {
			case underDir(inputDir, romPath):
				rep.Unmatched++ // staged duplicate: the set deviates from 1G1R
			case underDir(outputDir, romPath):
				rep.Duplicate++ // already-promoted echo: idempotent re-verify
			default:
				rep.Other++
			}
		default:
			rep.Other++
		}
	}
	rep.DatGames = rep.Found + rep.Missing
	return rep, nil
}

// promotedBytes sums the on-disk sizes of the FOUND output paths — what
// this run put in the games tree (missing files read as 0).
func promotedBytes(paths []string) int64 {
	var total int64
	for _, p := range paths {
		if st, err := os.Stat(p); err == nil {
			total += st.Size()
		}
	}
	return total
}

// ---- tree helpers -----------------------------------------------------------

// dirHasFiles reports whether dir exists and holds at least one regular
// file anywhere below it (the script's `find -type f -print -quit`).
func dirHasFiles(dir string) bool {
	found := false
	_ = filepath.WalkDir(dir, func(_ string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil // unreadable entries read as empty, like find's
		}
		if !d.IsDir() {
			found = true
			return filepath.SkipAll
		}
		return nil
	})
	return found
}

// hasAria2Control reports whether any *.aria2 control file exists under
// dir — the runtime-authoritative in-flight check (the scan-time staging
// table is only a hint).
func hasAria2Control(dir string) bool {
	found := false
	_ = filepath.WalkDir(dir, func(_ string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if !d.IsDir() && strings.HasSuffix(d.Name(), ".aria2") {
			found = true
			return filepath.SkipAll
		}
		return nil
	})
	return found
}

// copyTree copies src into dst with rsync -a's quick-check semantics:
// a target file with identical size AND mtime is skipped (re-runs are
// cheap), everything else is copied with mode + mtime preserved.
// Returns the bytes copied and the files copied (skips not counted).
func copyTree(src, dst string) (bytes int64, files int, err error) {
	err = filepath.WalkDir(src, func(path string, d fs.DirEntry, werr error) error {
		if werr != nil {
			return werr
		}
		rel, rerr := filepath.Rel(src, path)
		if rerr != nil {
			return rerr
		}
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		if !d.Type().IsRegular() {
			return nil // sockets/fifos never travel
		}
		info, ierr := d.Info()
		if ierr != nil {
			return ierr
		}
		if tst, terr := os.Stat(target); terr == nil &&
			tst.Size() == info.Size() && tst.ModTime().Equal(info.ModTime()) {
			return nil // rsync quick-check: identical, skip
		}
		in, oerr := os.Open(path)
		if oerr != nil {
			return oerr
		}
		out, cerr := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, info.Mode().Perm())
		if cerr != nil {
			in.Close() //nolint:errcheck // best effort
			return cerr
		}
		n, cperr := io.Copy(out, in)
		syncErr := out.Sync()
		closeErr := out.Close()
		in.Close() //nolint:errcheck // read-only
		if cperr != nil {
			return cperr
		}
		if syncErr != nil {
			return syncErr
		}
		if closeErr != nil {
			return closeErr
		}
		// Preserve mtime (the quick-check key) + mode.
		if err := os.Chtimes(target, info.ModTime(), info.ModTime()); err != nil {
			return err
		}
		if err := os.Chmod(target, info.Mode().Perm()); err != nil {
			return err
		}
		bytes += n
		files++
		return nil
	})
	return bytes, files, err
}

func (r *Runner) logf(format string, args ...any) {
	if r.log != nil {
		r.log.Printf("igir: "+format, args...)
	}
}
