// Package generate is the launcher-DB generator (gauntlet plan §2 P6,
// goal 5): the SQLite store becomes the source of truth and this package
// renders the metadata.pegasus.txt files the kiosks' Pegasus instances
// read from the served trees (games/{cartridge,optical,modern}/<sys>/).
//
// It is where cartridge-scrape.sh's seed_launchable_metadata and
// split_pending semantics landed (D-P5b): every generated collection is
// launchable by construction (header + launch line + explicit game:/
// file: blocks), games whose files fail the completeness sniff move into
// a trailing "(Pending)" collection that lists but does NOT launch, and
// the whole file regenerates idempotently each run — the awk state
// machine's strip-and-rebuild behaviour reduces to a pure regeneration
// because we own the entire file instead of patching Skyscraper output.
//
// Safety contract (AC-5):
//   - bytes are built for EVERY system first, validated with our strict
//     parser (internal/pegasus) second, written third — a bad batch can
//     never leave a half-updated tree;
//   - writes are temp-sibling + fsync + rename; the previously served
//     file survives any failure untouched (kill-safety);
//   - output is byte-stable for unchanged store+filesystem state (no
//     timestamps, deterministic ordering everywhere);
//   - all file:/assets values are RELATIVE paths — kiosks mount the
//     trees elsewhere.
package generate

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/pegasus"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/pipeline"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// ErrBusy is returned when a generation is requested while one runs,
// mirroring the igir/scrape runners' contract (HTTP surfaces it as 409).
var ErrBusy = errors.New("generate: a generation is already running")

// Outcome labels for one system's generation step (run-detail JSON
// values — same vocabulary as the other runners).
const (
	OutcomeGenerated = "generated" // bytes built, validated, (written unless dry-run)
	OutcomeFailed    = "failed"    // build/validation/write error; old file intact
)

// PendingMarker opens the trailing pending section. The full marker LINE
// carries a manager suffix; the bare constant is what tests and future
// tooling match on.
const PendingMarker = "# jupiter-pending-section"

// CustomCollectionMarker opens each trailing custom-collection section
// (P7). The full marker LINE carries a manager suffix.
const CustomCollectionMarker = "# jupiter-custom-collection"

// pendingSummary is split_pending's exact wording — listed but not yet
// playable ("coming soon", never a dead black-screen launch).
const pendingSummary = "Still downloading or incomplete - listed but not yet playable."

const targetName = "metadata.pegasus.txt"

// processStartedAt approximates this process's birth (package-init time;
// nothing of ours runs earlier). The stale-temp sweep only reclaims
// residue older than it — see sweepStaleTemps.
var processStartedAt = time.Now()

// Magic-byte sniff constants (cartridge-scrape.sh rom_complete port).
const (
	mComprHDMagic = "MComprHD" // MComprHD v2+ header: 4d 43 6f 6d 70 72 48 44
	comprHDMagic  = "ComprHD"  // ComprHD v1 prefix (checked under v2)
	zipPKMagic    = "PK"       // every zip starts PK
)

// Options carries generation knobs. CustomCollections (P7) render as
// their own Pegasus collection blocks appended after the main+pending
// sections of EVERY member system's file — the D-P6b seam, now live.
type Options struct {
	// CustomCollections are the operator-defined collections: named
	// member lists keyed by (system, rel_path). Members that are hidden
	// or fail the completeness sniff never emit (hidden games are
	// excluded from generation by contract; a pending ROM inside a
	// launched collection would be a dead entry).
	CustomCollections []CustomCollection
}

// CustomCollection is one named collection's membership.
type CustomCollection struct {
	Title     string
	Shortname string // stable identity; unique across collections
	Summary   string // optional; omitted from the block when empty
	Members   []CollectionMember
}

// CollectionMember names one member game.
type CollectionMember struct {
	SystemKey string
	RelPath   string
}

// SystemOutcome is one system's result — the run detail's JSON shape.
type SystemOutcome struct {
	Sys         string `json:"Sys"`
	Outcome     string `json:"Outcome"`
	Err         string `json:"Err,omitempty"`
	Games       int    `json:"Games"`       // main-collection blocks
	Pending     int    `json:"Pending"`     // pending-collection blocks
	Collections int    `json:"Collections"` // custom-collection blocks emitted for this system
}

// Result summarizes one Generate pass.
type Result struct {
	Systems   []SystemOutcome
	Validated bool // no payload failed the strict parser
	DryRun    bool
}

// Generator builds metadata files from the store into the served trees.
// Pipeline, when set, is the shared heavy-job lock (ADV-P5-03): a
// generation refuses to start while a verify or scrape holds it.
type Generator struct {
	St            *store.Store
	CartridgeRoot string
	OpticalRoot   string
	ModernRoot    string
	Pipeline      *pipeline.Mutex

	mu       sync.Mutex
	running  bool
	lastErr  string
	lastOKAt string
}

// Configured reports whether the generator has its store and roots.
func (g *Generator) Configured() bool {
	return g.St != nil && g.CartridgeRoot != "" && g.OpticalRoot != "" && g.ModernRoot != ""
}

// State snapshots the in-memory status for UI affordances.
type State struct {
	Running   bool
	LastOKAt  string
	LastError string
}

// State returns the current in-memory generation status — the UI seam
// mirroring the igir/scrape/scanner runners' State() accessors.
func (g *Generator) State() State {
	g.mu.Lock()
	defer g.mu.Unlock()
	return State{Running: g.running, LastOKAt: g.lastOKAt, LastError: g.lastErr}
}

func (g *Generator) bucketRoot(bucket string) string {
	switch bucket {
	case "optical":
		return g.OpticalRoot
	case "modern":
		return g.ModernRoot
	default:
		return g.CartridgeRoot
	}
}

// Generate regenerates every populated system's launcher DB file.
// Per-system failures are recorded in the Result (and make the run row
// "error") without aborting the batch; the returned error is reserved
// for configuration/busy/run-recording problems.
func (g *Generator) Generate(dryRun bool) (Result, error) {
	return g.GenerateOptions(dryRun, Options{})
}

// GenerateOptions is Generate with the P7 curation seam wired through.
func (g *Generator) GenerateOptions(dryRun bool, opts Options) (Result, error) {
	if !g.Configured() {
		return Result{}, errors.New("generate: not configured")
	}
	g.mu.Lock()
	if g.running {
		g.mu.Unlock()
		return Result{}, ErrBusy
	}
	g.running = true
	g.mu.Unlock()
	defer func() {
		g.mu.Lock()
		g.running = false
		g.mu.Unlock()
	}()

	if g.Pipeline != nil && !g.Pipeline.TryAcquire() {
		return Result{}, ErrBusy
	}
	if g.Pipeline != nil {
		defer g.Pipeline.Release()
	}

	runID, err := g.St.StartRun("generate")
	if err != nil {
		return Result{}, fmt.Errorf("generate: record run: %w", err)
	}

	res := Result{DryRun: dryRun, Validated: true}

	// Phase 1 — BUILD: pure functions of (store rows, filesystem), no IO
	// to the targets yet.
	type payload struct {
		dir   string
		bytes []byte
		oc    SystemOutcome
	}
	var payloads []payload
	customs := customViewsBySystem(opts.CustomCollections)
	systems, serr := g.St.Systems()
	if serr != nil {
		res.Validated = false
		g.finishRun(runID, &res)
		return res, fmt.Errorf("generate: systems: %w", serr)
	}
	for _, sys := range systems {
		games, qerr := g.St.SystemGamesWithMeta(sys.Key)
		if qerr != nil {
			res.Systems = append(res.Systems, SystemOutcome{Sys: sys.Key,
				Outcome: OutcomeFailed, Err: "store query: " + qerr.Error()})
			continue
		}
		if len(games) == 0 {
			continue // nothing visible to generate; no file churn
		}
		sysDir := filepath.Join(g.bucketRoot(sys.Bucket), sys.Key)
		// A vanished tree (unmounted bucket, removed dir) with live DB
		// rows is an inconsistency worth surfacing loudly: fail the
		// system instead of dying mid-write or creating the dir.
		if fi, derr := os.Stat(sysDir); derr != nil || !fi.IsDir() {
			res.Systems = append(res.Systems, SystemOutcome{Sys: sys.Key,
				Outcome: OutcomeFailed, Err: fmt.Sprintf("games dir missing: %s", sysDir)})
			continue
		}
		data, oc, berr := g.renderSystem(sys, games, sysDir, customs[sys.Key])
		oc.Sys = sys.Key
		if berr != nil {
			oc.Outcome = OutcomeFailed
			oc.Err = berr.Error()
			res.Systems = append(res.Systems, oc)
			continue
		}
		payloads = append(payloads, payload{dir: sysDir, bytes: data, oc: oc})
	}

	// Phase 2 — VALIDATE: every candidate through the strict parser +
	// invariants BEFORE anything is renamed. A failing payload drops out
	// here; its old file stays served.
	var writeables []payload
	for _, p := range payloads {
		f, perr := pegasus.Parse(bytes.NewReader(p.bytes))
		if perr == nil {
			perr = f.Validate()
		}
		if perr != nil {
			res.Validated = false
			p.oc.Outcome = OutcomeFailed
			p.oc.Err = "validation refused output: " + perr.Error()
			logf("%s: %s", p.oc.Sys, p.oc.Err)
			res.Systems = append(res.Systems, p.oc)
			continue
		}
		writeables = append(writeables, p)
	}

	// Phase 3 — WRITE: atomic rename per system; a dry run stops short.
	for _, p := range writeables {
		switch {
		case dryRun:
			p.oc.Outcome = OutcomeGenerated
		default:
			if werr := writeAtomic(filepath.Join(p.dir, targetName), p.bytes); werr != nil {
				p.oc.Outcome = OutcomeFailed
				p.oc.Err = "write: " + werr.Error()
				logf("%s: %s", p.oc.Sys, p.oc.Err)
			} else {
				p.oc.Outcome = OutcomeGenerated
			}
		}
		res.Systems = append(res.Systems, p.oc)
	}

	// ADV-P6-02: a kill -9 between CreateTemp and Rename strands a
	// dot-prefixed .tmp sibling in the SERVED tree forever — the next
	// igir verify counts it Extra → amber. Reclaim residue in every dir
	// this run generated into (validation-failed dirs included: they are
	// still generated dirs) before recording the run row. A dry run must
	// not touch the tree at all (P7's diff-preview purity).
	if !dryRun && len(payloads) > 0 {
		seen := map[string]bool{}
		var dirs []string
		for _, p := range payloads {
			if !seen[p.dir] {
				seen[p.dir] = true
				dirs = append(dirs, p.dir)
			}
		}
		sweepStaleTemps(dirs)
	}

	status := g.finishRun(runID, &res)
	g.mu.Lock()
	defer g.mu.Unlock()
	g.lastErr = ""
	switch {
	case !res.Validated:
		g.lastErr = "validation refused generated output"
	case status != "ok":
		failed := 0
		for _, oc := range res.Systems {
			if oc.Outcome == OutcomeFailed {
				failed++
			}
		}
		g.lastErr = fmt.Sprintf("%d system(s) failed generation", failed)
	}
	if status == "ok" {
		// LastOKAt was declared but never assigned (ADV-P6-06) — the UI
		// seam read as "never ran" forever. Mirror the igir/scrape/scanner
		// runners: stamp on a fully ok run, under the same lock as the
		// snapshot readers.
		g.lastOKAt = time.Now().UTC().Format(time.RFC3339)
	}
	return res, nil
}

// finishRun records the run row and reports the status it wrote
// ("ok"|"error") — the State stamping decision reads it back.
func (g *Generator) finishRun(runID int64, res *Result) string {
	status := "ok"
	for _, oc := range res.Systems {
		if oc.Outcome == OutcomeFailed {
			status = "error"
			break
		}
	}
	detail, _ := json.Marshal(struct {
		Systems   []SystemOutcome `json:"Systems"`
		Validated bool            `json:"Validated"`
		DryRun    bool            `json:"DryRun"`
	}{res.Systems, res.Validated, res.DryRun})
	if err := g.St.FinishRun(runID, status, string(detail)); err != nil {
		logf("finish run: %v", err)
	}
	return status
}

// customView is one custom collection's per-system projection: the
// header facts plus the member rel_paths that belong to THIS system.
type customView struct {
	title     string
	shortname string
	summary   string
	members   map[string]bool
}

// customViewsBySystem groups options' collections into per-system views,
// each sorted by shortname (byte-stable emission order). A collection
// with no member in a system produces no view there.
func customViewsBySystem(colls []CustomCollection) map[string][]customView {
	out := map[string][]customView{}
	for _, c := range colls {
		bySys := map[string]map[string]bool{}
		for _, m := range c.Members {
			set := bySys[m.SystemKey]
			if set == nil {
				set = map[string]bool{}
				bySys[m.SystemKey] = set
			}
			set[m.RelPath] = true
		}
		for sys, set := range bySys {
			out[sys] = append(out[sys], customView{
				title: c.Title, shortname: c.Shortname, summary: c.Summary, members: set,
			})
		}
	}
	for sys := range out {
		vs := out[sys]
		sort.Slice(vs, func(i, j int) bool { return vs[i].shortname < vs[j].shortname })
	}
	return out
}

// section is one trailing collection group: header lines plus game
// blocks (the pending split and each custom collection).
type section struct {
	header []string
	blocks [][]string
}

// renderSystem builds one system's full file bytes: main collection
// header + complete-game blocks, then the pending section when any game
// failed the completeness sniff, then one section per custom collection
// with members here. Deterministic by construction.
func (g *Generator) renderSystem(sys store.SystemRow, games []store.GameMetaRow, sysDir string, customs []customView) ([]byte, SystemOutcome, error) {
	var oc SystemOutcome

	// Launch mapping mirrors scrape.go exactly: retroarch+core wins,
	// else the dedicated emulator wrapper, else there is nothing
	// playable to emit — refuse loudly rather than write an unlaunchable
	// collection (the exact hole seed_launchable_metadata existed to fill).
	var launch string
	switch {
	case sys.Core != "" && sys.Core != "-":
		launch = "jupiter-retroarch -L " + sys.Core
	case sys.Emulator != "":
		launch = "jupiter-" + sys.Emulator
	default:
		return nil, oc, fmt.Errorf("%s: no core or emulator mapped; cannot build launch line", sys.Key)
	}

	header := []string{
		"collection: " + sanitizeValue(sys.Collection),
		"shortname: " + sys.Key,
		`launch: ` + launch + ` "{file.path}"`,
	}

	blocks := make([][]string, len(games))
	playable := make([]bool, len(games))
	var mainBlocks, pendBlocks [][]string
	for i, gm := range games {
		blocks[i] = gameBlock(gm, sysDir)
		playable[i] = romComplete(filepath.Join(sysDir, gm.RelPath))
		if playable[i] {
			mainBlocks = append(mainBlocks, blocks[i])
			oc.Games++
		} else {
			pendBlocks = append(pendBlocks, blocks[i])
			oc.Pending++
		}
	}

	pendHeader := []string{
		PendingMarker + " (managed by arcade-webapp)",
		"collection: " + sanitizeValue(sys.Collection) + " (Pending)",
		"shortname: " + sys.Key + "-pending",
		"summary: " + pendingSummary,
	}
	var sections []section
	if len(pendBlocks) > 0 {
		sections = append(sections, section{header: pendHeader, blocks: pendBlocks})
	}

	// Custom collections (P7): one section per collection with visible
	// AND playable members in this system, each carrying this system's
	// launch line so its entries are launchable (Pegasus associates a
	// game block with the last-declared collection; repeating the member
	// block under the new header is the documented multi-membership
	// idiom). Hidden members never reach `games`, so they are excluded
	// by construction; pending members are skipped — listed-not-playable
	// belongs to the pending section only.
	for _, cv := range customs {
		var memberBlocks [][]string
		for i, gm := range games {
			if cv.members[gm.RelPath] && playable[i] {
				memberBlocks = append(memberBlocks, blocks[i])
			}
		}
		if len(memberBlocks) == 0 {
			continue // no live members here: no churn, no empty shell block
		}
		colHeader := []string{
			CustomCollectionMarker + " (managed by arcade-webapp)",
			"collection: " + sanitizeValue(cv.title),
			"shortname: " + cv.shortname,
		}
		if s := sanitizeValue(cv.summary); s != "" {
			colHeader = append(colHeader, "summary: "+s)
		}
		colHeader = append(colHeader, `launch: `+launch+` "{file.path}"`)
		sections = append(sections, section{header: colHeader, blocks: memberBlocks})
		oc.Collections++
	}

	return assemble(header, mainBlocks, sections), oc, nil
}

// gameBlock renders one game's entry lines: title/file plus enrichment
// and media refs when present. Shared by the main collection and every
// custom-collection repeat so the two can never disagree.
func gameBlock(gm store.GameMetaRow, sysDir string) []string {
	base := filepath.Base(gm.RelPath)
	title := sanitizeValue(strings.TrimSuffix(base, filepath.Ext(base)))
	if title == "" { // degenerate name (.nes alone): still list the file
		title = sanitizeValue(base)
	}
	block := []string{
		"game: " + title,
		"file: " + sanitizeValue(gm.RelPath),
	}
	addField := func(key, val string) {
		if val = sanitizeValue(val); val != "" {
			block = append(block, key+": "+val)
		}
	}
	addField("description", gm.Description)
	addField("release", gm.Release)
	addField("developer", gm.Developer)
	addField("publisher", gm.Publisher)
	addField("genre", gm.Genre)
	addField("rating", gm.Rating)
	for _, a := range mediaAssets(sysDir, strings.TrimSuffix(base, filepath.Ext(base))) {
		block = append(block, "assets."+a.key+": "+a.value)
	}
	return block
}

// assemble joins blocks with blank-line separators (Pegasus entry
// terminator), appends the trailing sections (pending first, then custom
// collections), and terminates the file with exactly one newline —
// byte-stable by shape.
func assemble(header []string, main [][]string, sections []section) []byte {
	var b strings.Builder
	b.WriteString(strings.Join(header, "\n"))
	emit := func(blocks [][]string) {
		for _, blk := range blocks {
			b.WriteString("\n\n")
			b.WriteString(strings.Join(blk, "\n"))
		}
	}
	emit(main)
	for _, sec := range sections {
		b.WriteString("\n\n")
		b.WriteString(strings.Join(sec.header, "\n"))
		emit(sec.blocks)
	}
	b.WriteString("\n")
	return []byte(b.String())
}

// sanitizeValue makes a store string safe for the raw-value format:
// newlines (which would end the entry and orphan the rest) collapse to
// "; " separators, other control bytes drop, surrounding space trims.
// Colons inside values are safe — Pegasus splits on the FIRST colon.
func sanitizeValue(s string) string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	s = strings.ReplaceAll(s, "\r", "\n")
	parts := strings.Split(s, "\n")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.Map(func(r rune) rune {
			if r < 0x20 || r == 0x7f {
				return -1 // control bytes never belong in a value
			}
			return r
		}, p)
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return strings.Join(out, "; ")
}

// romComplete reports whether a ROM file's magic bytes match its format
// — cartridge-scrape.sh rom_complete ported. While aria2 torrents it
// PREALLOCATES files as zeros; emulators abort on those, so they must
// list as pending, not playable. Only formats with reliable leading
// magic are checked; everything else is optimistically complete (a raw
// .iso legitimately starts with zeros). Unreadable → incomplete.
func romComplete(path string) bool {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".chd":
		head := readHead(path, len(mComprHDMagic))
		// MComprHD (v2+) or the ComprHD (v1) prefix.
		return strings.HasPrefix(head, mComprHDMagic) || strings.HasPrefix(head, comprHDMagic)
	case ".zip":
		return readHead(path, len(zipPKMagic)) == zipPKMagic
	default:
		return true
	}
}

// readHead reads at most n leading bytes. The od-equivalent: read EXACTLY
// n bytes, never scan the file hunting for non-NUL characters.
func readHead(path string, n int) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close() //nolint:errcheck // read-only
	buf := make([]byte, n)
	got, err := io.ReadFull(f, buf)
	if err != nil && err != io.EOF && err != io.ErrUnexpectedEOF {
		return ""
	}
	return string(buf[:got])
}

// assetRef is one media reference: the Pegasus assets.<key> stem and the
// relative path value.
type assetRef struct{ key, value string }

// mediaAssets lists the composited artwork for one game under the
// Skyscraper layout media/<base-without-ext>/ — sorted, stems deduped
// (first extension wins alphabetically). Absent dir → no references.
func mediaAssets(sysDir, baseNoExt string) []assetRef {
	dir := filepath.Join(sysDir, "media", baseNoExt)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if e.Type().IsRegular() {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	var out []assetRef
	seenStem := map[string]bool{}
	for _, name := range names {
		stem := strings.TrimSuffix(name, filepath.Ext(name))
		if seenStem[stem] {
			continue
		}
		seenStem[stem] = true
		out = append(out, assetRef{
			key:   stem,
			value: "media/" + baseNoExt + "/" + name,
		})
	}
	return out
}

// tempSiblingRe matches the dot-prefixed metadata temp siblings
// writeAtomic creates — the current pid-stamped shape AND any legacy
// no-pid residue left by older binaries.
var tempSiblingRe = regexp.MustCompile(`^\.` + regexp.QuoteMeta(targetName) + `\..+\.tmp$`)

// tempOwnerPid extracts the pid embedded in a current-shape temp name
// (".metadata.pegasus.txt.<pid>.<rand>.tmp"); 0 for legacy shapes or
// unparseable names.
func tempOwnerPid(name string) int {
	mid := strings.TrimSuffix(strings.TrimPrefix(name, "."+targetName+"."), ".tmp")
	fields := strings.SplitN(mid, ".", 2)
	pid, err := strconv.Atoi(fields[0])
	if err != nil || pid <= 0 {
		return 0
	}
	return pid
}

// sweepStaleTemps reclaims kill -9 residue: dot-prefixed *.tmp siblings
// of metadata.pegasus.txt that two guards both disown.
//
// Guard 1 (pid): generations are serialized within THIS process by the
// shared pipeline mutex, so no concurrent generation of ours can hold a
// live temp while the sweep runs; the pid check is belt-and-braces for
// any future caller that sweeps outside that serialization.
//
// Guard 2 (mtime): anything younger than this process may belong to
// ANOTHER live webapp instance (overlapping restarts share the served
// trees) — only residue predating our start is reclaimable debris. Our
// own crash residue is reclaimed by the next process generation.
func sweepStaleTemps(dirs []string) {
	for _, dir := range dirs {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue // vanished dir: nothing to reclaim
		}
		for _, e := range entries {
			name := e.Name()
			if !tempSiblingRe.MatchString(name) {
				continue
			}
			info, err := e.Info()
			if err != nil || !info.Mode().IsRegular() {
				continue
			}
			if tempOwnerPid(name) == os.Getpid() {
				continue
			}
			if info.ModTime().After(processStartedAt) {
				continue
			}
			if rerr := os.Remove(filepath.Join(dir, name)); rerr != nil {
				logf("temp sweep %s: %v", filepath.Join(dir, name), rerr)
				continue
			}
			logf("swept stale temp sibling %s in %s", name, filepath.Base(dir))
		}
	}
}

// writeAtomic installs data at path without EVER truncating the target:
// temp sibling in the same directory (so rename is atomic on-dataset),
// fsync'd before close, mode normalized, then renamed over the old
// file. Any failure removes the temp and leaves the previous file
// byte-intact — an interrupted generation degrades to "no change", the
// kiosk-visible contract AC-5 demands. The temp name carries this
// process's pid so the post-run stale-temp sweep (and igir's artifact
// classifier) can attribute residue precisely.
func writeAtomic(path string, data []byte) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, "."+targetName+"."+strconv.Itoa(os.Getpid())+".*.tmp")
	if err != nil {
		return fmt.Errorf("temp file: %w", err)
	}
	name := tmp.Name()
	remove := func() { _ = tmp.Close(); _ = os.Remove(name) }
	if _, err := tmp.Write(data); err != nil {
		remove()
		return fmt.Errorf("write: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		remove()
		return fmt.Errorf("fsync: %w", err)
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(name)
		return fmt.Errorf("close: %w", err)
	}
	if err := os.Chmod(name, 0o644); err != nil {
		_ = os.Remove(name)
		return fmt.Errorf("chmod: %w", err)
	}
	if err := os.Rename(name, path); err != nil {
		_ = os.Remove(name)
		return fmt.Errorf("rename over %s: %w", filepath.Base(path), err)
	}
	// Best-effort dir fsync so the rename itself is durable.
	if d, derr := os.Open(dir); derr == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	return nil
}

func logf(format string, args ...any) {
	log.Printf("generate: "+format, args...)
}
