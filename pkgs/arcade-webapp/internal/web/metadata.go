// Metadata UI (gauntlet P5, goal 4): the Skyscraper control surface —
// RomM's structural forfeit (ADR-0002 criterion 4: no coverage
// telemetry, no gap worklist, no scrape-queue control).
//
// This file carries:
//   - GET /metadata + GET /partials/metadata: per-system table
//     (description/cover coverage % from the games-table scrape flags +
//     scrape_coverage, cache-entry count, last scrape run summary, run
//     history with run-over-run deltas), "Scrape all" + per-system
//     scrape actions, a progressbar while a batch is in flight. The
//     fragment polls every 3s ONLY while a run is active (scrapes are
//     long and quota-metered; an idle page stays quiet).
//   - POST /metadata/scrape ("scrape all systems with ROM files"),
//     POST /systems/{system}/scrape, POST /systems/{systemKey}/games/
//     {id}/scrape — all through the Driver's serialized slot; a second
//     concurrent request is rejected deterministically with 409 (the
//     claim happens in-request, unlike the verify handlers' swallow-
//     ErrBusy-in-goroutine ordering).
//   - the kind=scrape run detail rendering (per-system outcome lines,
//     never raw JSON — ADV-P1-05).
package web

import (
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/scrape"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// WithScrape wires the P5 metadata engine: the Skyscraper driver
// (nil = the page renders its "not configured" state).
func WithScrape(d *scrape.Driver) Option {
	return func(s *Server) { s.sc = d }
}

// metaDrillDownPoints caps a row's history block (bounded store scan;
// a sparkline, not a ledger) — the verify drill-down's shape.
const metaDrillDownPoints = 5

// ---- view models ----------------------------------------------------------

type metaRowVM struct {
	Key, Collection   string
	Games             int64
	Desc, Cover       int64 // games with has_description / has_cover
	DescPct, CoverPct int   // -1 unknown (no games to cover)
	CacheEntries      int64
	RefreshedAgo      string // last coverage recompute, relative
	// Last scrape attempt for this system (newest kind=scrape run that
	// names it), plus the bounded run history with deltas.
	LastOutcome string // "" never scraped
	LastAgo     string
	LastErr     string
	History     []metaPointVM
	CanScrape   bool
}

// metaPointVM is one history line: a run's outcome plus its delta
// against the next-older point ("Δ+2 covered" = two more description+
// cover flags than the previous run recorded).
type metaPointVM struct {
	FinishedHuman string
	Status        string
	Outcome       string
	Desc, Cover   int64
	DeltaCovered  string // "" on the oldest point (no prior run to diff)
}

type metadataVM struct {
	Configured bool // driver wired
	State      scrape.State
	Error      string
	Rows       []metaRowVM
	IdleCount  int
	// Aggregate chips over systems WITH games: fully covered (desc and
	// cover at 100%), partially covered, cold (nothing scraped yet).
	NFull, NPartial, NCold int
	// Launcher-DB section (P6): the Regenerate affordance + the
	// kind=generate run history. Lives here because regeneration is
	// metadata-tree news and the fragment is the shared swap target.
	GenLog genLogVM
	Meta   pageMeta
	Now    time.Time
}

// metaCoveragePct renders covered*100/total, -1 when nothing can be
// covered (mirrors SystemSummary.CoveragePct's unknown contract).
func metaCoveragePct(covered, total int64) int {
	if total <= 0 {
		return -1
	}
	p := int(covered * 100 / total)
	if p > 100 {
		p = 100
	}
	return p
}

// fetchMetadata assembles the metadata page's view model.
func (s *Server) fetchMetadata() metadataVM {
	vm := metadataVM{
		Configured: s.sc != nil && s.sc.Configured(),
		Now:        time.Now(),
	}
	if s.sc != nil {
		vm.State = s.sc.State()
	}
	vm.Meta = pageMeta{Title: "metadata", Sub: "metadata & scraping", ActiveMeta: true}
	vm.GenLog = s.fetchGenLog()

	rows, err := s.st.ScrapeSummary()
	if err != nil {
		log.Printf("web: metadata: %v", err)
		vm.Error = "coverage summary unavailable"
		return vm
	}
	for _, r := range rows {
		row := metaRowVM{
			Key:          r.Key,
			Collection:   r.Collection,
			Games:        r.Games,
			Desc:         r.Desc,
			Cover:        r.Cover,
			DescPct:      metaCoveragePct(r.Desc, r.Games),
			CoverPct:     metaCoveragePct(r.Cover, r.Games),
			CacheEntries: r.CacheEntries,
		}
		if r.ComputedAt != "" {
			row.RefreshedAgo = relTime(vm.Now, r.ComputedAt)
		}
		// Drill-down: the persisted run history with deltas (read
		// failures degrade to "no history", never a broken page — same
		// policy as the verify drill-down).
		if hist, herr := s.st.SystemScrapeHistory(r.Key, metaDrillDownPoints); herr == nil {
			for i, p := range hist {
				mp := metaPointVM{
					FinishedHuman: relTime(vm.Now, p.FinishedAt),
					Status:        p.Status,
					Outcome:       p.Outcome,
					Desc:          p.Desc,
					Cover:         p.Cover,
				}
				if i+1 < len(hist) { // newest-first; [i+1] is the previous run
					mp.DeltaCovered = fmt.Sprintf("%+d",
						(p.Desc+p.Cover)-(hist[i+1].Desc+hist[i+1].Cover))
				}
				row.History = append(row.History, mp)
			}
			if len(hist) > 0 {
				row.LastOutcome = hist[0].Outcome
				row.LastAgo = relTime(vm.Now, hist[0].FinishedAt)
				row.LastErr = hist[0].Err
			}
		} else {
			log.Printf("web: metadata history %s: %v", r.Key, herr)
		}
		row.CanScrape = vm.Configured && !vm.State.Running

		switch {
		case r.Games == 0:
			vm.IdleCount++
			continue
		case r.Desc >= r.Games && r.Cover >= r.Games && r.Desc+r.Cover > 0:
			vm.NFull++
		case r.Desc == 0 && r.Cover == 0:
			vm.NCold++
		default:
			vm.NPartial++
		}
		vm.Rows = append(vm.Rows, row)
	}
	return vm
}

// ---- handlers ---------------------------------------------------------------

func (s *Server) handleMetadataPage(w http.ResponseWriter, _ *http.Request) {
	vm := s.fetchMetadata()
	s.render(w, http.StatusOK, "layout-metadata", vm)
}

func (s *Server) handlePartialMetadata(w http.ResponseWriter, _ *http.Request) {
	vm := s.fetchMetadata()
	s.render(w, http.StatusOK, "partial-metadata", vm)
}

// handleScrapeAll kicks a background scrape of every catalogue system
// holding ROM files. Mutating endpoint: htmx-only (hxRequestOK). A second
// submit while one runs answers 409 BEFORE spawning anything — the
// driver's slot claim is synchronous, so the busy rejection is
// deterministic (and the panel already shows the running state).
func (s *Server) handleScrapeAll(w http.ResponseWriter, r *http.Request) {
	if !hxRequestOK(r) {
		http.Error(w, "htmx requests only", http.StatusForbidden)
		return
	}
	if err := s.scrapeStart(func() error { return s.sc.StartAll() }); err != nil {
		s.renderScrapeError(w, err)
		return
	}
	vm := s.fetchMetadata()
	s.render(w, http.StatusAccepted, "partial-metadata", vm)
}

// handleScrapeSystem kicks a one-system scrape (the row button).
func (s *Server) handleScrapeSystem(w http.ResponseWriter, r *http.Request) {
	if !hxRequestOK(r) {
		http.Error(w, "htmx requests only", http.StatusForbidden)
		return
	}
	sys := r.PathValue("system")
	if !s.systemExists(sys) {
		http.Error(w, "unknown system "+sys, http.StatusNotFound)
		return
	}
	if err := s.scrapeStart(func() error { return s.sc.StartOne(sys) }); err != nil {
		s.renderScrapeError(w, err)
		return
	}
	vm := s.fetchMetadata()
	s.render(w, http.StatusAccepted, "partial-metadata", vm)
}

// handleScrapeGame kicks one ROM's re-scrape from the game-detail page —
// the plan's per-game action, wired to Driver.ScrapeGame (--startat/
// --endat windows on the gather passes). The answer swaps the page's
// #game-actions region so the button flips to its in-flight state.
func (s *Server) handleScrapeGame(w http.ResponseWriter, r *http.Request) {
	if !hxRequestOK(r) {
		http.Error(w, "htmx requests only", http.StatusForbidden)
		return
	}
	sys := r.PathValue("systemKey")
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil { // non-numeric ids read as absent, not 500
		http.NotFound(w, r)
		return
	}
	g, err := s.st.GetGame(sys, id)
	if err != nil {
		http.Error(w, "game lookup failed", http.StatusInternalServerError)
		log.Printf("web: game scrape %s/%d: %v", sys, id, err)
		return
	}
	if g == nil {
		http.NotFound(w, r)
		return
	}
	if err := s.scrapeStart(func() error { return s.sc.StartGame(sys, g.RelPath) }); err != nil {
		s.renderScrapeError(w, err)
		return
	}
	vm := s.fetchGameActions(g)
	s.render(w, http.StatusAccepted, "game-actions", vm)
}

// scrapeStart guards the not-configured state and delegates to start —
// every scrape POST funnels through here so 503/409 stay consistent.
func (s *Server) scrapeStart(start func() error) error {
	if s.sc == nil || !s.sc.Configured() {
		return errScrapeUnconfigured
	}
	return start()
}

type scrapeStartError string

const errScrapeUnconfigured = scrapeStartError("scrape not configured (Skyscraper binary missing)")

func (e scrapeStartError) Error() string { return string(e) }

// renderScrapeError maps a failed start onto the house status codes:
// unconfigured → 503 (consistent with dlControl/acquire), busy → 409
// Conflict (the operator asked twice; the first ask is still running).
func (s *Server) renderScrapeError(w http.ResponseWriter, err error) {
	var uerr scrapeStartError
	if errors.As(err, &uerr) {
		http.Error(w, string(uerr), http.StatusServiceUnavailable)
		return
	}
	if errors.Is(err, scrape.ErrBusy) {
		http.Error(w, "a scrape is already running", http.StatusConflict)
		return
	}
	log.Printf("web: scrape start: %v", err)
	http.Error(w, "scrape could not be started", http.StatusInternalServerError)
}

// ---- game actions region ----------------------------------------------------

// gameActionsVM backs the game-detail page's #game-actions region (the
// re-scrape button + its in-flight state). Hide/show stays a disabled
// affordance: curation lands in P7.
type gameActionsVM struct {
	SystemKey string
	GameID    int64
	Hidden    bool
	CanScrape bool
	Running   bool
}

func (s *Server) fetchGameActions(g *store.GameDetail) gameActionsVM {
	vm := gameActionsVM{
		SystemKey: g.SystemKey,
		GameID:    g.ID,
		Hidden:    g.Hidden,
	}
	if s.sc != nil {
		st := s.sc.State()
		vm.Running = st.Running
		vm.CanScrape = s.sc.Configured() && !st.Running
	}
	return vm
}

// ---- run detail rendering ---------------------------------------------------

// scrapeRunDetail mirrors the driver's runs.detail JSON (the store keeps
// its own mirror for history parsing — see store.SystemScrapeHistory).
type scrapeRunDetail struct {
	Systems []struct {
		Sys     string `json:"Sys"`
		Outcome string `json:"Outcome"`
		Err     string `json:"Err,omitempty"`
		Desc    int64  `json:"Desc"`
		Cover   int64  `json:"Cover"`
	} `json:"Systems"`
}

// runDetailForKind handles the 'scrape' kind: one outcome line per
// system, capped, with coverage counts (called from runDetail in
// server.go).
func scrapeRunDetailHTML(detail string) (template.HTML, bool) {
	var d scrapeRunDetail
	if err := json.Unmarshal([]byte(detail), &d); err != nil {
		return "", false
	}
	esc := template.HTMLEscapeString
	var b string
	for i, oc := range d.Systems {
		if i >= 4 {
			b += fmt.Sprintf("<br><em>(+%d more systems)</em>", len(d.Systems)-4)
			break
		}
		line := fmt.Sprintf("%s: %s", esc(oc.Sys), esc(oc.Outcome))
		if oc.Outcome == scrape.OutcomeScraped {
			line += fmt.Sprintf(" · desc=%d cover=%d", oc.Desc, oc.Cover)
		}
		if oc.Err != "" {
			line += " — " + esc(truncate(oc.Err, 80))
		}
		b += "<br>" + line
	}
	return template.HTML(b), true
}
