// Verify UI (gauntlet P3, goals 1+3): the DAT manager + igir runner
// surfaces — RomM's structural forfeit (ADR-0002 criteria 1+3).
//
// This file carries:
//   - the verify page + its 2s-polled fragment (igir runs are
//     minutes-long): per-system table (DAT date/age, staged files, last
//     verify summary, promote state, report link), verify / verify-all /
//     DAT-refresh actions, a progressbar while a batch is in flight;
//   - the shared zero-unmatched classifier both pills render from
//     (green: every DAT game found + nothing unmatched; amber: missing
//     DAT games; red: unmatched input/duplicates/other; grey: no DAT or
//     never verified);
//   - the verify run detail rendering (per-system outcome lines, never
//     raw JSON — ADV-P1-05);
//   - report serving (catalogue-keyed whitelist under the scratch
//     reports dir — no path traversal).
package web

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/dats"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/igir"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/scanner"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// WithPipeline wires the P3 features: the igir verify runner and the DAT
// manager (either nil = that feature renders its "not configured" state).
func WithPipeline(runner *igir.Runner, fetcher *dats.Fetcher) Option {
	return func(s *Server) {
		s.ig, s.df = runner, fetcher
	}
}

// Verify-state labels (the zero-unmatched indicator's classes).
const (
	VerifyStateUnknown   = "unknown"   // never verified (grey)
	VerifyStateUnchecked = "unchecked" // promoted without a DAT (grey)
	VerifyStateVerified  = "verified"  // found==dat_games, nothing extra (green)
	VerifyStateMissing   = "missing"   // DAT games missing from the staged set (amber)
	VerifyStateExtra     = "extra"     // games-tree files the DAT doesn't claim (amber)
	VerifyStateUnmatched = "unmatched" // unmatched staged input / other deviations (red)
)

// classifyVerify derives the per-system zero-unmatched state from the
// last ingested report. Order is severity: red beats amber beats green.
//
// DUPLICATE is deliberately NOT red: on a re-verify the output tree
// already holds the first run's promotions (COPY semantics keep the
// staged input for aria2), and igir re-sees those input files as
// duplicates of the output — counting them red would flip every green
// system red on its second verify. Input-side duplicates DO count (they
// fold into Unmatched at parse time); only the output-side echo is
// benign. Proven against the real igir 5.3.0 (P3 VM bring-up).
func classifyVerify(v store.VerifyResult, present bool) string {
	if !present {
		return VerifyStateUnknown
	}
	if v.Unchecked != 0 {
		return VerifyStateUnchecked
	}
	if v.Unmatched > 0 || v.Other > 0 {
		return VerifyStateUnmatched
	}
	if v.DatGames == 0 {
		return VerifyStateUnknown
	}
	if v.Missing > 0 || v.Found < v.DatGames {
		return VerifyStateMissing
	}
	if v.Extra > 0 {
		return VerifyStateExtra
	}
	return VerifyStateVerified
}

// verifyStateChip renders the pill for a classified state + its counts.
// Shared by the card wall, the downloads system table, and the verify
// page — one indicator, one implementation.
func verifyStateChip(state string, v store.VerifyResult) template.HTML {
	switch state {
	case VerifyStateVerified:
		title := fmt.Sprintf("%d of %d DAT games found, 0 unmatched", v.Found, v.DatGames)
		if v.Duplicate > 0 {
			title += fmt.Sprintf(" (%d already-promoted echo)", v.Duplicate)
		}
		return template.HTML(fmt.Sprintf(`<span class="pill ok" title="%s">verified</span>`, title))
	case VerifyStateUnmatched:
		n := v.Unmatched + v.Other
		return template.HTML(fmt.Sprintf(`<span class="pill stale" title="%d found / %d missing / %d unmatched">%d unmatched</span>`, v.Found, v.Missing, n, n))
	case VerifyStateMissing:
		return template.HTML(fmt.Sprintf(`<span class="pill warn" title="%d of %d DAT games found">%d missing</span>`, v.Found, v.DatGames, v.Missing))
	case VerifyStateExtra:
		return template.HTML(fmt.Sprintf(`<span class="pill warn" title="all %d DAT games found; %d games-tree file(s) the DAT doesn't claim">%d extra</span>`, v.DatGames, v.Extra, v.Extra))
	case VerifyStateUnchecked:
		return template.HTML(fmt.Sprintf(`<span class="pill unknown" title="no DAT — promoted unchecked (%s)">unchecked</span>`, HumanBytes(v.PromotedBytes)))
	default:
		return `<span class="pill unknown">unknown</span>`
	}
}

// ---- view models ----------------------------------------------------------

type verifyRowVM struct {
	Key, Collection, Bucket string
	// DAT currency (from dat_info — refreshed by both the scanner and
	// the DAT manager).
	DATDate     string
	DATAgeDays  int // -1 unknown
	DATAgeHuman string
	DATMapped   bool   // a McLean DAT exists for this system
	DATURL      string // where a refresh would fetch from ("" when unmapped)
	// Staging (scan-time summary — labeled as such on the page).
	StagedFiles int64
	StagedBytes string
	InFlight    bool // .aria2 control files seen at scan time
	// Last verify.
	State         string // classifyVerify output
	Counts        store.VerifyResult
	CountsValid   bool
	FinishedAgo   string
	PromotedHuman string
	HasReport     bool
	// LastAttemptFailed: the system's NEWEST verify run errored without
	// ingesting (the parse-failure early return ahead of
	// RecordVerifyResult) — the counts/pill above show the last GOOD
	// report, and the marker says so instead of implying all is well
	// (ADV-P3-02).
	LastAttemptFailed bool
	// P4 drill-down, loaded only for offending systems (last verify has
	// unmatched>0 or extra>0): the persisted per-file offender list and
	// the recent-run history with run-over-run deltas.
	OffenderFiles []string
	History       []verifyPointVM
	// Button affordances.
	CanVerify bool
}

// verifyDrillDownPoints caps the history block (bounded store scan; a
// sparkline, not a ledger).
const verifyDrillDownPoints = 5

// verifyPointVM is one history line in the drill-down: a run's outcome
// plus its delta against the next-older point ("Δ+2 unmatched" = two
// more unmatched files than the previous run).
type verifyPointVM struct {
	FinishedHuman  string // relative age, like the rest of the page
	Found          int
	Unmatched      int
	Extra          int    // shown only when non-zero
	DeltaUnmatched string // "" on the oldest point (no prior run to diff)
}

type verifyVM struct {
	Configured     bool // igir wired
	DATsConfigured bool // DAT manager wired
	Runner         igir.State
	DATsRunning    bool
	Error          string
	Rows           []verifyRowVM
	IdleCount      int
	// Aggregate: how many systems sit in each state (the header chips).
	NVerified, NMissing, NExtra, NUnmatched, NUnchecked, NUnknown int
	Meta                                                          pageMeta
	Now                                                           time.Time
}

// fetchVerify assembles the verify page's view model.
func (s *Server) fetchVerify() verifyVM {
	vm := verifyVM{
		Configured:     s.ig != nil && s.ig.Configured(),
		DATsConfigured: s.df != nil,
		Now:            time.Now(),
	}
	if s.ig != nil {
		vm.Runner = s.ig.State()
	}
	if s.df != nil {
		vm.DATsRunning = s.df.Running()
	}
	vm.Meta = pageMeta{Title: "verify", Sub: "verify & organize", ActiveVerify: true}

	summary, err := s.st.SystemSummary()
	if err != nil {
		log.Printf("web: verify: %v", err)
		vm.Error = "system summary unavailable"
		return vm
	}
	staged := map[string]store.StagingRow{}
	if rows, err := s.st.StagingRows(); err == nil {
		for _, r := range rows {
			staged[r.SystemKey] = r
		}
	}
	lastAttempt := s.lastVerifyAttempts()

	for _, sys := range summary {
		st := staged[sys.Key]
		row := verifyRowVM{
			Key:           sys.Key,
			Collection:    sys.Collection,
			Bucket:        sys.Bucket,
			DATDate:       sys.DATDate,
			DATAgeDays:    -1,
			DATMapped:     false,
			StagedFiles:   st.Files,
			StagedBytes:   HumanBytes(st.Bytes),
			InFlight:      st.InFlight,
			Counts:        sys.Verify,
			CountsValid:   sys.VerifyPresent,
			PromotedHuman: HumanBytes(sys.Verify.PromotedBytes),
			HasReport:     sys.Verify.ReportPath != "",
		}
		if sys.DATDate != "" {
			row.DATAgeDays = scannerAgeDays(sys.DATDate, vm.Now)
			row.DATAgeHuman = ageDaysHuman(row.DATAgeDays)
		}
		if s.df != nil {
			row.DATURL = dats.URLFor(s.df.BaseURL, sys.Key)
		}
		row.DATMapped = dats.McLeanDATs[sys.Key] != "" // mapping is static
		row.State = classifyVerify(sys.Verify, sys.VerifyPresent)
		// ADV-P3-02 pill honesty: a re-verify whose report failed to
		// parse never reaches RecordVerifyResult, so the pill keeps the
		// last GOOD ingest (right — the report is the authority) but
		// must say so when the newest attempt died. The RunID
		// comparison excludes failed runs whose own report WAS ingested
		// (igir non-zero exit + parseable report records counts too —
		// that pill is not stale).
		if at, ok := lastAttempt[sys.Key]; ok &&
			at.Outcome == igir.OutcomeFailed && at.RunID > sys.Verify.RunID {
			row.LastAttemptFailed = true
		}
		if sys.Verify.FinishedAt != "" {
			row.FinishedAgo = relTime(vm.Now, sys.Verify.FinishedAt)
		}
		// P4 drill-down: offending systems (red/amber deviations) get
		// their persisted per-file list + a bounded run history with
		// deltas. Read failures degrade to "no drill-down", never a
		// broken page (same policy as the staging map above).
		if sys.VerifyPresent && (sys.Verify.Unmatched > 0 || sys.Verify.Extra > 0) {
			if files, err := s.st.VerifyUnmatched(sys.Verify.RunID, sys.Key); err == nil {
				row.OffenderFiles = files
			} else {
				log.Printf("web: verify: unmatched files %s: %v", sys.Key, err)
			}
			if hist, err := s.st.SystemVerifyHistory(sys.Key, verifyDrillDownPoints); err == nil {
				for i, p := range hist {
					vp := verifyPointVM{
						FinishedHuman: relTime(vm.Now, p.FinishedAt),
						Found:         p.Found,
						Unmatched:     p.Unmatched,
						Extra:         p.Extra,
					}
					if i+1 < len(hist) { // hist is newest-first; [i+1] is the previous run
						vp.DeltaUnmatched = fmt.Sprintf("%+d", p.Unmatched-hist[i+1].Unmatched)
					}
					row.History = append(row.History, vp)
				}
			} else {
				log.Printf("web: verify: history %s: %v", sys.Key, err)
			}
		}
		switch row.State {
		case VerifyStateVerified:
			vm.NVerified++
		case VerifyStateMissing:
			vm.NMissing++
		case VerifyStateExtra:
			vm.NExtra++
		case VerifyStateUnmatched:
			vm.NUnmatched++
		case VerifyStateUnchecked:
			vm.NUnchecked++
		default:
			vm.NUnknown++
		}
		row.CanVerify = vm.Configured && !vm.Runner.Running

		// The verify page keeps every catalogue system visible (it is
		// the operator's worklist, not a health wall) — but systems with
		// no signal at all collapse into the idle count like P1.
		if sys.GameCount == 0 && sys.DATDate == "" && st.Files == 0 && !sys.VerifyPresent {
			vm.IdleCount++
			continue
		}
		vm.Rows = append(vm.Rows, row)
	}
	return vm
}

// lastAttemptScanRuns bounds the run-table scan behind the
// last-attempt-failed marker: well beyond the status partial's 8-row
// window, still one cheap indexed query + parse on the 2s poll.
const lastAttemptScanRuns = 100

// verifyAttempt is one system's newest recorded verify outcome.
type verifyAttempt struct {
	RunID   int64
	Outcome string
}

// lastVerifyAttempts maps system key -> the newest verify outcome the
// runs table holds for it (runs arrive newest-first; the first hit per
// system wins, so a per-system re-verify correctly outranks an older
// verify-all). Runs with unparseable detail — still running — are
// skipped. Feeds the ADV-P3-02 honesty marker in fetchVerify.
func (s *Server) lastVerifyAttempts() map[string]verifyAttempt {
	out := map[string]verifyAttempt{}
	runs, err := s.st.RecentRuns(lastAttemptScanRuns)
	if err != nil {
		return out // no marker rather than a broken page
	}
	for _, run := range runs {
		if run.Kind != "verify" {
			continue
		}
		var d verifyRunDetail
		if err := json.Unmarshal([]byte(run.Detail), &d); err != nil {
			continue
		}
		for _, oc := range d.Systems {
			if _, seen := out[oc.Sys]; !seen {
				out[oc.Sys] = verifyAttempt{RunID: run.ID, Outcome: oc.Outcome}
			}
		}
	}
	return out
}

// scannerAgeDays/ageDaysHuman/relTime are thin aliases so this file
// reads standalone; scanner.AgeDays is the shared parser (one parser,
// the DAT chip and the scanner agree — see scanner.AgeDays).
func scannerAgeDays(date string, now time.Time) int { return scanner.AgeDays(date, now) }

func ageDaysHuman(days int) string {
	switch {
	case days < 0:
		return "?"
	default:
		return fmt.Sprintf("%dd", days)
	}
}

func relTime(now time.Time, ts string) string {
	t, err := time.Parse(time.RFC3339, ts)
	if err != nil {
		return ts
	}
	return ageFrom(now, t.UTC().Format(time.RFC3339))
}

// ---- handlers ---------------------------------------------------------------

func (s *Server) handleVerifyPage(w http.ResponseWriter, _ *http.Request) {
	vm := s.fetchVerify()
	s.render(w, http.StatusOK, "layout-verify", vm)
}

func (s *Server) handlePartialVerify(w http.ResponseWriter, _ *http.Request) {
	vm := s.fetchVerify()
	s.render(w, http.StatusOK, "partial-verify", vm)
}

// handleVerifyAll kicks a background verify of every catalogue system.
// Mutating endpoint: htmx-only (hxRequestOK), like every POST here.
func (s *Server) handleVerifyAll(w http.ResponseWriter, r *http.Request) {
	if !hxRequestOK(r) {
		http.Error(w, "htmx requests only", http.StatusForbidden)
		return
	}
	if s.ig == nil || !s.ig.Configured() {
		http.Error(w, "verify not configured (igir binary missing)", http.StatusServiceUnavailable)
		return
	}
	go func() {
		outcomes, err := s.ig.VerifyAll()
		if err != nil && !errors.Is(err, igir.ErrBusy) {
			log.Printf("web: verify-all: %v", err)
			return
		}
		log.Printf("web: verify-all: %d systems", len(outcomes))
	}()
	vm := s.fetchVerify()
	s.render(w, http.StatusAccepted, "partial-verify", vm)
}

// handleVerifySystem kicks a one-system verify (the "re-verify" button).
func (s *Server) handleVerifySystem(w http.ResponseWriter, r *http.Request) {
	if !hxRequestOK(r) {
		http.Error(w, "htmx requests only", http.StatusForbidden)
		return
	}
	if s.ig == nil || !s.ig.Configured() {
		http.Error(w, "verify not configured (igir binary missing)", http.StatusServiceUnavailable)
		return
	}
	sys := r.PathValue("system")
	if !s.systemExists(sys) {
		http.Error(w, "unknown system "+sys, http.StatusNotFound)
		return
	}
	go func() {
		if _, err := s.ig.Verify([]string{sys}); err != nil && !errors.Is(err, igir.ErrBusy) {
			log.Printf("web: verify %s: %v", sys, err)
		}
	}()
	vm := s.fetchVerify()
	s.render(w, http.StatusAccepted, "partial-verify", vm)
}

// handleDATRefresh fetches every mapped system's DAT (failures are
// per-system warnings inside the run, never a 5xx here). The batch runs
// in the background OUTLIVING the request: context.Background(), never
// r.Context() — net/http cancels the request context when this handler
// returns, which would kill every fetch mid-batch ("context canceled";
// proven RED→GREEN by TestDATRefreshAllSurvivesHandlerReturn). Each
// fetch keeps its own 60s cap, like the scheduled refresh in main.go.
func (s *Server) handleDATRefresh(w http.ResponseWriter, r *http.Request) {
	if !hxRequestOK(r) {
		http.Error(w, "htmx requests only", http.StatusForbidden)
		return
	}
	if s.df == nil {
		http.Error(w, "DAT manager not configured", http.StatusServiceUnavailable)
		return
	}
	systems, err := s.st.Systems()
	if err != nil {
		http.Error(w, "system lookup failed", http.StatusInternalServerError)
		return
	}
	go func() {
		res := s.df.Refresh(context.Background(), systems)
		log.Printf("web: dat refresh: %d fetched, %d unmapped, %d warnings", res.Fetched, res.Unmapped, len(res.Warnings))
	}()
	vm := s.fetchVerify()
	s.render(w, http.StatusAccepted, "partial-verify", vm)
}

// handleDATRefreshSystem fetches one system's DAT on demand. An unmapped
// system (wiiu/pcfx/zxspectrum…) surfaces the mapping error on the
// fragment — a 200-with-error, not a 5xx: the page stays legible.
func (s *Server) handleDATRefreshSystem(w http.ResponseWriter, r *http.Request) {
	if !hxRequestOK(r) {
		http.Error(w, "htmx requests only", http.StatusForbidden)
		return
	}
	if s.df == nil {
		http.Error(w, "DAT manager not configured", http.StatusServiceUnavailable)
		return
	}
	sys := r.PathValue("system")
	var row *store.SystemRow
	systems, err := s.st.Systems()
	if err != nil {
		http.Error(w, "system lookup failed", http.StatusInternalServerError)
		return
	}
	for i := range systems {
		if systems[i].Key == sys {
			row = &systems[i]
			break
		}
	}
	if row == nil {
		http.Error(w, "unknown system "+sys, http.StatusNotFound)
		return
	}
	if err := s.df.RefreshSystem(r.Context(), *row); err != nil {
		vm := s.fetchVerify()
		vm.Error = sys + ": " + err.Error()
		s.render(w, http.StatusOK, "partial-verify", vm)
		return
	}
	vm := s.fetchVerify()
	s.render(w, http.StatusOK, "partial-verify", vm)
}

// handleVerifyReport serves one system's last igir report CSV. The
// system key is whitelisted against the catalogue and the file is read
// from exactly <reportDir>/<sys>.csv — no user-controlled path segments.
func (s *Server) handleVerifyReport(w http.ResponseWriter, r *http.Request) {
	sys := strings.TrimSuffix(r.PathValue("system"), ".csv")
	if !s.systemExists(sys) {
		http.NotFound(w, r)
		return
	}
	if s.ig == nil {
		http.Error(w, "verify not configured", http.StatusServiceUnavailable)
		return
	}
	path := filepath.Join(s.ig.ReportDir(), sys+".csv")
	f, err := os.Open(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			http.NotFound(w, r)
			return
		}
		http.Error(w, "report unavailable", http.StatusInternalServerError)
		return
	}
	defer f.Close() //nolint:errcheck // read-only
	w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(http.StatusOK)
	if _, err := io.Copy(w, f); err != nil {
		log.Printf("web: report %s: %v", sys, err)
	}
}

// systemExists checks the catalogue-backed systems table.
func (s *Server) systemExists(key string) bool {
	systems, err := s.st.Systems()
	if err != nil {
		return false
	}
	for _, sys := range systems {
		if sys.Key == key {
			return true
		}
	}
	return false
}

// ---- run detail rendering ---------------------------------------------------

// verifyRunDetail mirrors the runner's runs.detail JSON.
type verifyRunDetail struct {
	Systems  []igir.SystemOutcome `json:"Systems"`
	Promoted bool                 `json:"Promoted"`
}

// datFetchRunDetail mirrors the DAT manager's runs.detail JSON.
type datFetchRunDetail struct {
	Systems  int      `json:"Systems"`
	Fetched  int      `json:"Fetched"`
	Unmapped int      `json:"Unmapped"`
	Warnings []string `json:"Warnings"`
}

// runDetailForKind renders the human-facing detail cell for the P3/P5
// run kinds (called from runDetail in server.go; keeps that dispatcher
// boring). Verify runs: one line per system, capped, with report links.
// DAT fetches: the batch counts + up to three warnings. Scrapes: one
// outcome+coverage line per system (see metadata.go).
func runDetailForKind(r store.Run) (template.HTML, bool) {
	switch r.Kind {
	case "verify":
		var d verifyRunDetail
		if err := json.Unmarshal([]byte(r.Detail), &d); err != nil {
			return "", false
		}
		var b strings.Builder
		for i, oc := range d.Systems {
			if i >= 4 {
				fmt.Fprintf(&b, "<br><em>(+%d more systems)</em>", len(d.Systems)-4)
				break
			}
			esc := template.HTMLEscapeString
			line := fmt.Sprintf("%s: %s", esc(oc.Sys), esc(oc.Outcome))
			if oc.Outcome == "verified" || oc.Outcome == "failed" {
				line += fmt.Sprintf(" %d/%d", oc.Found, oc.DatGames)
				if oc.Unmatched > 0 {
					line += fmt.Sprintf(" · %d unmatched", oc.Unmatched)
				}
				if oc.Missing > 0 {
					line += fmt.Sprintf(" · %d missing", oc.Missing)
				}
				if oc.Extra > 0 {
					line += fmt.Sprintf(" · %d extra", oc.Extra)
				}
				if oc.Duplicate > 0 {
					line += fmt.Sprintf(" · %d echo", oc.Duplicate)
				}
			}
			if oc.Err != "" {
				line += " — " + esc(truncate(oc.Err, 80))
			}
			b.WriteString("<br>" + line)
		}
		return template.HTML(strings.TrimPrefix(b.String(), "<br>")), true
	case "dat-fetch":
		var d datFetchRunDetail
		if err := json.Unmarshal([]byte(r.Detail), &d); err != nil {
			return "", false
		}
		out := template.HTMLEscapeString(fmt.Sprintf("%d fetched · %d unmapped · %d warnings", d.Fetched, d.Unmapped, len(d.Warnings)))
		for i, warn := range d.Warnings {
			if i >= 3 {
				out += fmt.Sprintf(" <em>(+%d more)</em>", len(d.Warnings)-3)
				break
			}
			out += "<br>⚠ " + template.HTMLEscapeString(truncate(warn, 120))
		}
		return template.HTML(out), true
	case "scrape":
		return scrapeRunDetailHTML(r.Detail)
	default:
		return "", false
	}
}
