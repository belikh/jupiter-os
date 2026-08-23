// Package web serves the jupiterOS Arcade webapp: one NixOS-native app on
// europa owning the whole cartridge-ROM pipeline (DAT currency, aria2
// downloads, igir verify, Skyscraper metadata, Pegasus launcher-DB
// generation, curation). See docs/adr/0002-arcade-webapp-custom-vs-romm.md
// and docs/plans/arcade-webapp-gauntlet.md.
//
// Phase 1 scope: the pipeline dashboard — per-system card wall (ROM
// count/size, DAT date+age, verify state, art coverage), scan status with
// an on-demand rescan, recent runs, totals. Stack per ADR-0002 D4: Go
// stdlib net/http + html/template + htmx (one vendored file under static/,
// with its upstream license) + hand-rolled CSS (Catppuccin Mocha). The
// dynamic fragments poll every 10s; there is no client JS beyond htmx.
package web

import (
	"embed"
	"encoding/json"
	"fmt"
	"html/template"
	"io/fs"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/aria2"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/dats"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/generate"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/igir"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/scanner"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/scrape"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

//go:embed templates static
var content embed.FS

// Server holds the webapp's HTTP routes. The mux is built once in New so
// the handler tree is immutable per process.
type Server struct {
	handler http.Handler
	st      *store.Store
	scan    *scanner.Scanner
	tmpl    *template.Template
	// Download control (P2): nil client = not configured. See downloads.go.
	a2 *aria2.Client
	dl dlPaths
	// Verify + DAT manager (P3): nil = not configured. See verify.go.
	ig *igir.Runner
	df *dats.Fetcher
	// Game art root (P4): Skyscraper-cache media dir, "" = SVG posters
	// only. See art.go.
	artDir string
	// Metadata engine (P5): nil = not configured. See metadata.go.
	sc *scrape.Driver
	// Launcher-DB generator (P6): nil = not configured. See generate.go.
	gen *generate.Generator
}

// New builds the webapp's HTTP handler over an opened store and scanner,
// plus optional features (WithAria2 for download control).
func New(st *store.Store, scan *scanner.Scanner, opts ...Option) (*Server, error) {
	tmpl, err := template.New("").Funcs(template.FuncMap{
		"humanBytes":      HumanBytes,
		"age":             ageFrom,
		"runPill":         runPill,
		"runDuration":     runDuration,
		"runDetail":       runDetail,
		"verifyPill":      verifyPill,
		"verifyStateChip": verifyStateChip,
		"gamePill":        gamePill,
		"dlStatusPill":    dlStatusPill,
		"dlStateClass":    dlStateClass,
		"speed":           speedHuman,
		"mul100":          mul100,
	}).ParseFS(content, "templates/*.html")
	if err != nil {
		return nil, fmt.Errorf("web: parse templates: %w", err)
	}

	s := &Server{handler: nil, st: st, scan: scan, tmpl: tmpl}
	for _, opt := range opts {
		opt(s)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.handleHealthz)
	mux.HandleFunc("GET /static/", s.handleStatic)
	mux.HandleFunc("GET /partials/status", s.handlePartialStatus)
	mux.HandleFunc("GET /partials/systems", s.handlePartialSystems)
	mux.HandleFunc("GET /partials/downloads-summary", s.handlePartialDownloadsSummary)
	mux.HandleFunc("GET /downloads", s.handleDownloads)
	mux.HandleFunc("GET /partials/downloads", s.handlePartialDownloads)
	mux.HandleFunc("POST /systems/{system}/acquire", s.handleAcquire)
	mux.HandleFunc("POST /downloads/{gid}/pause", s.dlControl("pause"))
	mux.HandleFunc("POST /downloads/{gid}/resume", s.dlControl("resume"))
	mux.HandleFunc("POST /downloads/{gid}/remove", s.dlControl("remove"))
	// P3: verify & organize + DAT currency + torrent staging.
	mux.HandleFunc("GET /verify", s.handleVerifyPage)
	mux.HandleFunc("GET /partials/verify", s.handlePartialVerify)
	mux.HandleFunc("POST /verify", s.handleVerifyAll)
	mux.HandleFunc("POST /systems/{system}/verify", s.handleVerifySystem)
	mux.HandleFunc("POST /dats/refresh", s.handleDATRefresh)
	mux.HandleFunc("POST /systems/{system}/dat-refresh", s.handleDATRefreshSystem)
	mux.HandleFunc("GET /verify/reports/{system}", s.handleVerifyReport)
	// P4: library browsing — gallery, its htmx fragment and detail page.
	mux.HandleFunc("GET /library", s.handleLibraryPage)
	mux.HandleFunc("GET /partials/library", s.handlePartialLibrary)
	mux.HandleFunc("GET /systems/{systemKey}/games/{id}", s.handleGameDetail)
	mux.HandleFunc("GET /art/{systemKey}/{gameID}", s.handleArt)
	// P5: metadata engine control — coverage page + scrape actions.
	mux.HandleFunc("GET /metadata", s.handleMetadataPage)
	mux.HandleFunc("GET /partials/metadata", s.handlePartialMetadata)
	mux.HandleFunc("POST /metadata/scrape", s.handleScrapeAll)
	mux.HandleFunc("POST /systems/{system}/scrape", s.handleScrapeSystem)
	mux.HandleFunc("POST /systems/{systemKey}/games/{id}/scrape", s.handleScrapeGame)
	mux.HandleFunc("POST /systems/{system}/stage-torrent", s.handleStageTorrent)
	mux.HandleFunc("POST /systems/{system}/stage-uri", s.handleStageURI)
	// P6: launcher-DB generation — the manual Regenerate action.
	mux.HandleFunc("POST /generate", s.handleGenerate)
	// P7: curation — hide/show toggles + custom collections CRUD UI.
	mux.HandleFunc("POST /systems/{systemKey}/games/{id}/hide", s.handleGameHideToggle)
	mux.HandleFunc("POST /systems/{system}/unhide-all", s.handleSystemUnhideAll)
	mux.HandleFunc("GET /collections", s.handleCollectionsPage)
	mux.HandleFunc("GET /partials/collections", s.handlePartialCollections)
	mux.HandleFunc("POST /collections/create", s.handleCollectionCreate)
	mux.HandleFunc("GET /collections/{id}", s.handleCollectionPage)
	mux.HandleFunc("POST /collections/{id}/update", s.handleCollectionUpdate)
	mux.HandleFunc("POST /collections/{id}/delete", s.handleCollectionDelete)
	mux.HandleFunc("POST /collections/{id}/add", s.handleCollectionAddGame)
	mux.HandleFunc("POST /collections/{id}/remove", s.handleCollectionRemoveGame)
	mux.HandleFunc("POST /rescan", s.handleRescan)
	mux.HandleFunc("GET /", s.handleIndex)
	s.handler = mux
	return s, nil
}

// Handler returns the rooted handler; main wires it into an http.Server.
func (s *Server) Handler() http.Handler { return s.handler }

// ---- view models ---------------------------------------------------------

type cardVM struct {
	Key          string
	Collection   string
	Bucket       string
	Active       bool
	GameCount    int64
	SizeHuman    string
	DATDate      string
	DATVersion   string
	DATAgeDays   int // -1 unknown
	DATAgeHuman  string
	DATAgeClass  string // ok | warn | stale | unknown
	CoveragePct  int    // -1 unknown
	CacheEntries int64
	Verified     int64
	Unmatched    int64
	// Verify pill (P3): the last report's classification + counts — the
	// system-level zero-unmatched indicator, live since P3.
	VerifyState  string
	VerifyCounts store.VerifyResult
}

type totalsVM struct {
	Systems       int
	ActiveSystems int
	Games         int64
	BytesHuman    string
	HealthLabel   string
	HealthClass   string
}

// pageMeta is what the shared topbar partial needs from any page's view
// model (title, the contextual health chip, which nav item is active).
type pageMeta struct {
	Title             string
	Sub               string
	HealthLabel       string
	HealthClass       string
	ActiveDash        bool
	ActiveLibrary     bool
	ActiveCollections bool // P7 curation pages
	ActiveDloads      bool
	ActiveVerify      bool
	ActiveMeta        bool
}

type incomingVM struct {
	Files      string
	BytesHuman string
}

type dashboardVM struct {
	Scan       scanner.State
	LastRun    *store.Run
	Runs       []store.Run
	Cards      []cardVM
	EmptyCount int
	Totals     totalsVM
	Incoming   incomingVM
	Meta       pageMeta
	Now        time.Time
}

// viewModel assembles the dashboard data from the store + scanner state.
func (s *Server) viewModel() (dashboardVM, error) {
	vm := dashboardVM{Now: time.Now(), Scan: s.scan.State()}
	vm.Meta = pageMeta{
		Title:      "pipeline",
		Sub:        "pipeline dashboard",
		ActiveDash: true,
	}

	summary, err := s.st.SystemSummary()
	if err != nil {
		return vm, err
	}
	vm.Totals.Systems = len(summary)
	for _, sys := range summary {
		c := cardVM{
			Key:          sys.Key,
			Collection:   sys.Collection,
			Bucket:       sys.Bucket,
			Active:       sys.Active(),
			GameCount:    sys.GameCount,
			SizeHuman:    HumanBytes(sys.TotalBytes),
			DATDate:      sys.DATDate,
			DATVersion:   sys.DATVersion,
			CoveragePct:  sys.CoveragePct(),
			CacheEntries: sys.CacheEntries,
			Verified:     sys.Verified,
			Unmatched:    sys.Unmatched,
			VerifyState:  classifyVerify(sys.Verify, sys.VerifyPresent),
			VerifyCounts: sys.Verify,
		}
		if sys.DATDate != "" {
			c.DATAgeDays = scanner.AgeDays(sys.DATDate, vm.Now)
		} else {
			c.DATAgeDays = -1
		}
		switch {
		case c.DATAgeDays < 0:
			c.DATAgeClass, c.DATAgeHuman = "unknown", "?"
		case c.DATAgeDays <= 30:
			c.DATAgeClass, c.DATAgeHuman = "ok", fmt.Sprintf("%dd", c.DATAgeDays)
		case c.DATAgeDays <= 90:
			c.DATAgeClass, c.DATAgeHuman = "warn", fmt.Sprintf("%dd", c.DATAgeDays)
		default:
			c.DATAgeClass, c.DATAgeHuman = "stale", fmt.Sprintf("%dd", c.DATAgeDays)
		}
		vm.Totals.Games += sys.GameCount
		if c.Active {
			vm.Totals.ActiveSystems++
			vm.Cards = append(vm.Cards, c)
		} else {
			vm.EmptyCount++
		}
	}

	vm.LastRun, err = s.st.LastRun()
	if err != nil {
		return vm, err
	}
	if vm.Runs, err = s.st.RecentRuns(8); err != nil {
		return vm, err
	}

	// Overall health, most urgent first: scan in flight, failed run,
	// warned run (part of the library state is unknown right now — e.g. an
	// unreadable bucket kept its previous rows per ADV-P1-03), stale DATs.
	vm.Totals.HealthLabel, vm.Totals.HealthClass = "healthy", "ok"
	warned := vm.LastRun != nil && runWarnings(*vm.LastRun) > 0
	switch {
	case vm.Scan.Running:
		vm.Totals.HealthLabel, vm.Totals.HealthClass = "scanning", "running"
	case vm.LastRun != nil && vm.LastRun.Status == "error":
		vm.Totals.HealthLabel, vm.Totals.HealthClass = "scan error", "error"
	case warned:
		if n := runWarnings(*vm.LastRun); n == 1 {
			vm.Totals.HealthLabel = "1 warning"
		} else {
			vm.Totals.HealthLabel = fmt.Sprintf("%d warnings", n)
		}
		vm.Totals.HealthClass = "warn"
	default:
		stale := 0
		for _, c := range vm.Cards {
			if c.DATAgeDays > 90 {
				stale++
			}
		}
		if stale > 0 {
			vm.Totals.HealthLabel = fmt.Sprintf("%d stale DATs", stale)
			vm.Totals.HealthClass = "warn"
		}
	}
	vm.Totals.BytesHuman = HumanBytes(totalBytes(summary))
	vm.Meta.HealthLabel, vm.Meta.HealthClass = vm.Totals.HealthLabel, vm.Totals.HealthClass

	if f := s.st.GetMeta("incoming_files"); f != "" {
		vm.Incoming.Files = f
		vm.Incoming.BytesHuman = HumanBytes(parseI64(s.st.GetMeta("incoming_bytes")))
	} else {
		vm.Incoming.Files, vm.Incoming.BytesHuman = "0", "0 B"
	}
	return vm, nil
}

func totalBytes(summary []store.SystemSummary) int64 {
	var t int64
	for _, s := range summary {
		t += s.TotalBytes
	}
	return t
}

func parseI64(s string) int64 {
	v, _ := strconv.ParseInt(s, 10, 64)
	return v
}

// ---- handlers --------------------------------------------------------------

func (s *Server) handleIndex(w http.ResponseWriter, r *http.Request) {
	// http.ServeMux registers "GET /" as a subtree match; anything not
	// caught by a more specific pattern lands here. Only the root is a page.
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	vm, err := s.viewModel()
	if err != nil {
		http.Error(w, "dashboard unavailable", http.StatusInternalServerError)
		log.Printf("web: viewModel: %v", err)
		return
	}
	s.render(w, http.StatusOK, "layout", vm)
}

func (s *Server) handlePartialStatus(w http.ResponseWriter, _ *http.Request) {
	vm, err := s.viewModel()
	if err != nil {
		http.Error(w, "status unavailable", http.StatusInternalServerError)
		log.Printf("web: viewModel: %v", err)
		return
	}
	s.render(w, http.StatusOK, "partial-status", vm)
}

func (s *Server) handlePartialSystems(w http.ResponseWriter, _ *http.Request) {
	vm, err := s.viewModel()
	if err != nil {
		http.Error(w, "cards unavailable", http.StatusInternalServerError)
		log.Printf("web: viewModel: %v", err)
		return
	}
	s.render(w, http.StatusOK, "partial-systems", vm)
}

// handleRescan kicks a background scan and answers with the refreshed
// status fragment (the button targets #status-panel, so the panel swap is
// the whole round-trip — no client JS). A second click while running is
// rejected by the scanner's ErrBusy guard and swallowed here: the panel
// already shows "running". Mutating endpoint: htmx-only (see hxRequestOK).
func (s *Server) handleRescan(w http.ResponseWriter, r *http.Request) {
	if !hxRequestOK(r) {
		http.Error(w, "htmx requests only", http.StatusForbidden)
		return
	}
	go func() {
		res, err := s.scan.Scan()
		if err != nil && err != scanner.ErrBusy {
			log.Printf("web: rescan: %v", err)
			return
		}
		log.Printf("web: rescan complete: %d systems, %d games, %d warnings", res.Systems, res.Games, len(res.Warnings))
	}()
	vm, err := s.viewModel()
	if err != nil {
		http.Error(w, "status unavailable", http.StatusInternalServerError)
		log.Printf("web: viewModel: %v", err)
		return
	}
	s.render(w, http.StatusAccepted, "partial-status", vm)
}

func (s *Server) handleStatic(w http.ResponseWriter, r *http.Request) {
	staticFS, err := fs.Sub(content, "static")
	if err != nil {
		http.Error(w, "static unavailable", http.StatusInternalServerError)
		return
	}
	http.StripPrefix("/static/", http.FileServerFS(staticFS)).ServeHTTP(w, r)
}

func (s *Server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok\n"))
}

func (s *Server) render(w http.ResponseWriter, status int, name string, vm any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	if err := s.tmpl.ExecuteTemplate(w, name, vm); err != nil {
		// Headers are sent; log and stop — a half-written page is the
		// honest failure mode for a streaming template.
		log.Printf("web: render %s: %v", name, err)
	}
}

// ---- template helpers -------------------------------------------------------

// HumanBytes renders a byte count in binary units ("1.4 MiB").
func HumanBytes(b int64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := int64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(b)/float64(div), "KMGTPE"[exp])
}

// ageFrom renders "3m ago"-style relative time for an RFC3339 timestamp.
func ageFrom(now time.Time, ts string) string {
	t, err := time.Parse(time.RFC3339, ts)
	if err != nil {
		return ts
	}
	d := now.Sub(t).Round(time.Second)
	switch {
	case d < time.Minute:
		return d.String() + " ago"
	case d < time.Hour:
		return d.Round(time.Minute).String() + " ago"
	case d < 24*time.Hour:
		return d.Round(time.Hour).String() + " ago"
	default:
		return fmt.Sprintf("%dd ago", int(d.Hours()/24))
	}
}

// runDetailJSON mirrors scanner.Result's JSON — the runs.detail payload.
type runDetailJSON struct {
	Systems  int      `json:"Systems"`
	Games    int64    `json:"Games"`
	Bytes    int64    `json:"Bytes"`
	Errors   int      `json:"Errors"`
	Warnings []string `json:"Warnings"`
}

// runWarnings counts the warnings recorded in a run's detail payload
// (0 when the detail is missing or not scanner-shaped).
func runWarnings(r store.Run) int {
	var d runDetailJSON
	if err := json.Unmarshal([]byte(r.Detail), &d); err != nil {
		return 0
	}
	return len(d.Warnings)
}

// runDetail renders a run's detail cell: kind-aware summaries (scan in
// this function; verify/dat-fetch via runDetailForKind in verify.go),
// anything else (error text, later phases' payloads) renders escaped and
// length-capped. Never raw JSON (ADV-P1-05: an operator reading the
// dashboard should not parse a JSON blob by eye).
func runDetail(r store.Run) template.HTML {
	if html, ok := runDetailForKind(r); ok {
		return html
	}
	var d runDetailJSON
	if err := json.Unmarshal([]byte(r.Detail), &d); err == nil && r.Kind == "scan" {
		parts := []string{
			fmt.Sprintf("%d systems", d.Systems),
			fmt.Sprintf("%d games", d.Games),
			HumanBytes(d.Bytes),
		}
		out := template.HTMLEscapeString(strings.Join(parts, " · "))
		for i, w := range d.Warnings {
			if i >= 3 {
				out += fmt.Sprintf(" <em>(+%d more)</em>", len(d.Warnings)-3)
				break
			}
			out += "<br>⚠ " + template.HTMLEscapeString(truncate(w, 120))
		}
		if d.Errors > 0 {
			out += fmt.Sprintf("<br>⛔ %d errors", d.Errors)
		}
		return template.HTML(out)
	}
	return template.HTML(template.HTMLEscapeString(truncate(r.Detail, 160)))
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n-1] + "…"
}

func runPill(status string) template.HTML {
	class := "unknown"
	switch status {
	case "ok":
		class = "ok"
	case "running":
		class = "running"
	case "error":
		class = "error"
	}
	return template.HTML(`<span class="pill ` + class + `">` + template.HTMLEscapeString(status) + `</span>`)
}

func runDuration(r store.Run) string {
	start, err := time.Parse(time.RFC3339, r.StartedAt)
	if err != nil {
		return "?"
	}
	if r.FinishedAt == "" {
		return "…"
	}
	end, err := time.Parse(time.RFC3339, r.FinishedAt)
	if err != nil {
		return "?"
	}
	return end.Sub(start).Round(time.Millisecond).String()
}

// verifyPill renders the card wall's verify chip. Live since P3: the
// classification comes from the last ingested igir report
// (verify_results), not the per-game aggregates — the report is the
// authoritative statement about the staged set. Unknown until the first
// verify run lands.
func verifyPill(c cardVM) template.HTML {
	return verifyStateChip(c.VerifyState, c.VerifyCounts)
}

// dlStatusPill renders a system's live download-state chip for the
// downloads systems table (error wins over downloading over queued).
func dlStatusPill(s systemDL) template.HTML {
	switch {
	case s.Errored:
		return `<span class="pill error">errored</span>`
	case s.Downloading:
		return `<span class="pill running">downloading</span>`
	case s.Queued:
		return `<span class="pill warn">queued</span>`
	default:
		return `<span class="pill unknown">—</span>`
	}
}

// speedHuman renders an int64 bytes/s value as "<x>/s" ("" for 0).
func speedHuman(b int64) string {
	if b <= 0 {
		return ""
	}
	return HumanBytes(b) + "/s"
}

// mul100 renders done*100/total (0 for total<=1 edge shapes) — the
// verify batch progressbar's width.
func mul100(done, total int) int {
	if total <= 0 {
		return 0
	}
	p := done * 100 / total
	if p > 100 {
		p = 100
	}
	return p
}

// dlStateClass maps an aria2 download status to the pill CSS class.
func dlStateClass(status string) string {
	switch status {
	case "active":
		return "running"
	case "paused", "waiting":
		return "warn"
	case "complete":
		return "ok"
	case "error":
		return "error"
	default:
		return "unknown" // removed
	}
}
