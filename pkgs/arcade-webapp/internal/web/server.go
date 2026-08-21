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
	"fmt"
	"html/template"
	"io/fs"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/scanner"
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
}

// New builds the webapp's HTTP handler over an opened store and scanner.
func New(st *store.Store, scan *scanner.Scanner) (*Server, error) {
	tmpl, err := template.New("").Funcs(template.FuncMap{
		"humanBytes":  HumanBytes,
		"age":         ageFrom,
		"runPill":     runPill,
		"runDuration": runDuration,
		"verifyPill":  verifyPill,
	}).ParseFS(content, "templates/*.html")
	if err != nil {
		return nil, fmt.Errorf("web: parse templates: %w", err)
	}

	s := &Server{handler: nil, st: st, scan: scan, tmpl: tmpl}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.handleHealthz)
	mux.HandleFunc("GET /static/", s.handleStatic)
	mux.HandleFunc("GET /partials/status", s.handlePartialStatus)
	mux.HandleFunc("GET /partials/systems", s.handlePartialSystems)
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
}

type totalsVM struct {
	Systems       int
	ActiveSystems int
	Games         int64
	BytesHuman    string
	HealthLabel   string
	HealthClass   string
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
	Now        time.Time
}

// viewModel assembles the dashboard data from the store + scanner state.
func (s *Server) viewModel() (dashboardVM, error) {
	vm := dashboardVM{Now: time.Now(), Scan: s.scan.State()}

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

	// Overall health: last-run errors dominate, then DAT staleness.
	vm.Totals.HealthLabel, vm.Totals.HealthClass = "healthy", "ok"
	if vm.Scan.Running {
		vm.Totals.HealthLabel, vm.Totals.HealthClass = "scanning", "running"
	} else if vm.LastRun != nil && vm.LastRun.Status == "error" {
		vm.Totals.HealthLabel, vm.Totals.HealthClass = "scan error", "error"
	} else {
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
// already shows "running".
func (s *Server) handleRescan(w http.ResponseWriter, _ *http.Request) {
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

func (s *Server) render(w http.ResponseWriter, status int, name string, vm dashboardVM) {
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

// verifyPill renders the verify-state chip from what the DB knows: fully
// verified → green, any unmatched → red, otherwise unknown (gray) — P1
// data is all-'unknown' until P3's igir ingestion flips states.
func verifyPill(c cardVM) template.HTML {
	switch {
	case c.GameCount > 0 && c.Verified == c.GameCount:
		return template.HTML(`<span class="pill ok">verified</span>`)
	case c.Unmatched > 0:
		return template.HTML(`<span class="pill stale">` + strconv.FormatInt(c.Unmatched, 10) + ` unmatched</span>`)
	default:
		return template.HTML(`<span class="pill unknown">unknown</span>`)
	}
}
