// Library UI (gauntlet P4, goals 1+4): the browsable game gallery —
// RomM's home turf (ADR-0002), where we win on integration: every card
// carries its per-game verify state from the P3 ingest.
//
// This file carries:
//   - GET /library and GET /partials/library: the filter bar + card grid
//     over store.ListGames (q/system/state/sort/page — all deep-linkable
//     URL params). The partial is the htmx swap region; the page wraps
//     it. Pagination is plain server-rendered links preserving params.
//   - GET /systems/{systemKey}/games/{id}: the detail page (art, chips,
//     facts, verify report link) with a back-link preserving the library
//     query. The hide/show action renders disabled — curation is P7.
//
// Titles are rel_path basenames minus extension until Skyscraper
// metadata lands (P5); the same string feeds search and the poster art.
package web

import (
	"fmt"
	"html/template"
	"log"
	"net/http"
	"net/url"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// libPageSize is the gallery's fixed page size (server-rendered
// pagination; 13 fixture games → two pages, a real library pages too).
const libPageSize = 10

// Per-game verify_state values (schema v1, store: unknown|verified|
// unmatched) — named here because the store keeps them as plain literals.
const (
	verifyStateUnknown   = "unknown"
	verifyStateVerified  = "verified"
	verifyStateUnmatched = "unmatched"
)

// gameVerifyStates is the per-game verify_state domain (schema v1):
// system-level states like missing/extra never appear on a game row.
var gameVerifyStates = map[string]bool{
	verifyStateUnknown:   true,
	verifyStateVerified:  true,
	verifyStateUnmatched: true,
}

// gameTitle derives a display title from a rel_path: basename without
// extension ("Starlit Vault (USA).nes" → "Starlit Vault (USA)"). One
// derivation shared by cards, detail and art so they can never disagree.
func gameTitle(relPath string) string {
	base := filepath.Base(relPath)
	return strings.TrimSuffix(base, filepath.Ext(base))
}

// displayTitle prefers the optional stored title (P8 eXo imports carry
// real `game:` values; their conf paths would render as "dosbox") and
// falls back to the filename derivation for catalogue rows.
func displayTitle(stored, relPath string) string {
	if stored != "" {
		return stored
	}
	return gameTitle(relPath)
}

// libURL rebuilds a /library URL with only the non-default params, in a
// deterministic key order (url.Values.Encode sorts) — pager hrefs and
// tests depend on that shape.
func libURL(q, system, state, sort, hidden string, page int) string {
	vals := url.Values{}
	if q != "" {
		vals.Set("q", q)
	}
	if system != "" {
		vals.Set("system", system)
	}
	if state != "" {
		vals.Set("state", state)
	}
	if sort != "" && sort != store.SortTitle {
		vals.Set("sort", sort)
	}
	if hidden != "" {
		vals.Set("hidden", hidden)
	}
	if page > 1 {
		vals.Set("page", strconv.Itoa(page))
	}
	if enc := vals.Encode(); enc != "" {
		return "/library?" + enc
	}
	return "/library"
}

// ---- view models ----------------------------------------------------------

type gameCardVM struct {
	ID          int64
	SystemKey   string
	Title       string
	SizeHuman   string
	VerifyState string
	Hidden      bool
	Href        string // detail route with back=<this library query>
	ArtURL      string // /art/<system>/<id> (SVG poster or scraped cover)
	Description string // truncated prose from games.description (4000 runes at ingest)
}

type libraryVM struct {
	Q, System, State, Sort string
	HiddenFilter           string // "" both | "1" hidden only | "0" visible only
	Page, TotalPages       int
	Total                  int64
	CountShown             int
	Games                  []gameCardVM
	Systems                []store.SystemRow // filter select options
	PrevURL, NextURL       string            // "" = no such page
	BackHere               string            // library URL the cards link back to
	Meta                   pageMeta
}

// fetchLibrary parses the URL params, clamps them to safe values and runs
// one ListGames page. Unknown state/sort values fall back to defaults
// rather than erroring — a hand-typed URL should browse, not 500.
func (s *Server) fetchLibrary(r *http.Request) (libraryVM, error) {
	qp := r.URL.Query()
	q := strings.TrimSpace(qp.Get("q"))
	if utf8.RuneCountInString(q) > 100 { // bound the FTS/LIKE expression
		q = string([]rune(q)[:100])
	}
	system := qp.Get("system")
	state := qp.Get("state")
	if !gameVerifyStates[state] {
		state = ""
	}
	sort := qp.Get("sort")
	switch sort {
	case "", store.SortTitle, store.SortSize, store.SortRecent:
	default:
		sort = ""
	}
	hiddenFilter := qp.Get("hidden")
	if hiddenFilter != "0" && hiddenFilter != "1" {
		hiddenFilter = "" // both
	}
	page := 1
	if p, err := strconv.Atoi(qp.Get("page")); err == nil && p > 1 {
		page = p
	}
	const maxPage = 100000 // clamp absurd manual pages before the offset math
	if page > maxPage {
		page = maxPage
	}

	vm := libraryVM{
		Q: q, System: system, State: state, Sort: sort,
		HiddenFilter: hiddenFilter,
		Meta:         pageMeta{Title: "library", Sub: "game library", ActiveLibrary: true},
	}
	vm.BackHere = "/library"
	if rq := r.URL.RawQuery; rq != "" {
		vm.BackHere += "?" + rq
	}
	if systems, err := s.st.Systems(); err == nil {
		vm.Systems = systems
	} else {
		log.Printf("web: library systems: %v", err) // select degrades to empty
	}

	opts := store.GameListOpts{
		Q: q, SystemKey: system, VerifyState: state, Sort: sort,
		Limit: libPageSize, Offset: (page - 1) * libPageSize,
	}
	switch hiddenFilter {
	case "1":
		t := true
		opts.Hidden = &t
	case "0":
		f := false
		opts.Hidden = &f
	}
	pg, err := s.st.ListGames(opts)
	if err != nil {
		return vm, err
	}
	totalPages := int((pg.Total + libPageSize - 1) / libPageSize)
	if totalPages < 1 {
		totalPages = 1
	}
	if page > totalPages { // out-of-range page: clamp and re-run once
		page = totalPages
		opts.Offset = (page - 1) * libPageSize
		pg, err = s.st.ListGames(opts)
		if err != nil {
			return vm, err
		}
	}
	vm.Page = page
	vm.TotalPages = totalPages
	vm.Total = pg.Total
	vm.CountShown = len(pg.Games)
	for _, g := range pg.Games {
		desc := g.Description
		if r := []rune(desc); len(r) > 160 {
			desc = string(r[:159]) + "…"
		}
		vm.Games = append(vm.Games, gameCardVM{
			ID:          g.ID,
			SystemKey:   g.SystemKey,
			Title:       displayTitle(g.Title, g.RelPath),
			SizeHuman:   HumanBytes(g.SizeBytes),
			VerifyState: g.VerifyState,
			Hidden:      g.Hidden,
			Href: fmt.Sprintf("/systems/%s/games/%d?back=%s",
				g.SystemKey, g.ID, url.QueryEscape(vm.BackHere)),
			ArtURL:      fmt.Sprintf("/art/%s/%d", g.SystemKey, g.ID),
			Description: desc,
		})
	}
	if page > 1 {
		vm.PrevURL = libURL(q, system, state, sort, hiddenFilter, page-1)
	}
	if page < totalPages {
		vm.NextURL = libURL(q, system, state, sort, hiddenFilter, page+1)
	}
	return vm, nil
}

// ---- handlers ---------------------------------------------------------------

func (s *Server) handleLibraryPage(w http.ResponseWriter, r *http.Request) {
	vm, err := s.fetchLibrary(r)
	if err != nil {
		http.Error(w, "library unavailable", http.StatusInternalServerError)
		log.Printf("web: library: %v", err)
		return
	}
	s.render(w, http.StatusOK, "layout-library", vm)
}

// handleGameHideToggle flips one game's hidden curation flag (P7): hide
// when visible, show when hidden — one endpoint, the toggle IS the API.
// Mutating endpoint: htmx-only (D-P2c). The write itself is a cheap
// indexed UPDATE that deliberately does NOT claim the pipeline slot; the
// launcher-DB regeneration it causes is requested through the shared
// coordinator (requestRegeneration — one worker, coalesced; ADV-P7-03).
// The answer swaps #game-actions with its refreshed self, so the button
// flips Hide↔Show without a reload.
func (s *Server) handleGameHideToggle(w http.ResponseWriter, r *http.Request) {
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
		log.Printf("web: game hide %s/%d: %v", sys, id, err)
		return
	}
	if g == nil {
		http.NotFound(w, r)
		return
	}
	if err := s.st.SetGameHidden(sys, g.RelPath, !g.Hidden); err != nil {
		http.Error(w, "hide failed", http.StatusInternalServerError)
		log.Printf("web: game hide %s/%s: %v", sys, g.RelPath, err)
		return
	}
	s.requestRegeneration(regenOriginCuration)
	ng, err := s.st.GetGame(sys, id)
	if err != nil || ng == nil {
		// The row existed a moment ago; a re-read failure here would make
		// the button state lie, so fail loudly instead.
		http.Error(w, "game lookup failed after toggle", http.StatusInternalServerError)
		log.Printf("web: game hide re-read %s/%d: %v", sys, id, err)
		return
	}
	s.render(w, http.StatusOK, "game-actions", s.fetchGameActions(ng))
}

func (s *Server) handlePartialLibrary(w http.ResponseWriter, r *http.Request) {
	vm, err := s.fetchLibrary(r)
	if err != nil {
		http.Error(w, "gallery unavailable", http.StatusInternalServerError)
		log.Printf("web: library partial: %v", err)
		return
	}
	s.render(w, http.StatusOK, "partial-library", vm)
}

// ---- game detail ------------------------------------------------------------

type gameDetailVM struct {
	ID        int64
	SystemKey string
	Title     string
	RelPath   string
	Bucket    string
	Core      string
	Emulator  string

	SizeHuman    string
	FirstSeenDay string // YYYY-MM-DD half of first_seen_at
	LastSeenDay  string
	LastSeenAgo  string

	VerifyState string
	HasReport   bool // a last-igir-report CSV exists for this system
	Hidden      bool

	// P5 metadata-engine fields: the best-effort cache flags (the
	// detail page's coverage facts) + the actions region (live
	// re-scrape button; hide/show stays a P7 affordance).
	HasDescription bool
	HasCover       bool
	// Description is the ingested prose (4000 runes, via
	// ApplyCacheEnrichment). Empty until scraped.
	Description string
	// P6 carry-in: the game file's SHA1 (scanner CacheID / igir ingest),
	// rendered in the facts block; "" until the next scan or a
	// checksum-bearing verify report fills it.
	SHA1    string
	Actions gameActionsVM

	ArtURL   string
	BackHref string // sanitized ?back= target (defaults /library)
	Meta     pageMeta
	Now      time.Time
}

// dayOf renders just the date half of an RFC3339 timestamp ("?" when
// unparseable — timestamps come from our own writes).
func dayOf(ts string) string {
	if t, err := time.Parse(time.RFC3339, ts); err == nil {
		return t.UTC().Format("2006-01-02")
	}
	return "?"
}

// safeBackPath validates the ?back= param: same-origin relative path or
// the default. Anything protocol-relative ("//"), absolute to another
// scheme, or carrying CR/LF falls back — the back-link must never become
// an open redirect.
func safeBackPath(s string) string {
	const def = "/library"
	if s == "" || len(s) > 500 {
		return def
	}
	if !strings.HasPrefix(s, "/") || strings.HasPrefix(s, "//") {
		return def
	}
	if strings.ContainsAny(s, "\\\r\n") {
		return def
	}
	return s
}

func (s *Server) handleGameDetail(w http.ResponseWriter, r *http.Request) {
	sys := r.PathValue("systemKey")
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil { // non-numeric ids read as absent, not 500
		http.NotFound(w, r)
		return
	}
	g, err := s.st.GetGame(sys, id)
	if err != nil {
		http.Error(w, "game lookup failed", http.StatusInternalServerError)
		log.Printf("web: game %s/%d: %v", sys, id, err)
		return
	}
	if g == nil {
		http.NotFound(w, r)
		return
	}
	title := displayTitle(g.Title, g.RelPath)
	vm := gameDetailVM{
		ID:             g.ID,
		SystemKey:      g.SystemKey,
		Title:          title,
		RelPath:        g.RelPath,
		Bucket:         g.System.Bucket,
		Core:           g.System.Core,
		Emulator:       g.System.Emulator,
		SizeHuman:      HumanBytes(g.SizeBytes),
		FirstSeenDay:   dayOf(g.FirstSeenAt),
		LastSeenDay:    dayOf(g.LastSeenAt),
		LastSeenAgo:    ageFrom(time.Now(), g.LastSeenAt),
		VerifyState:    g.VerifyState,
		Hidden:         g.Hidden,
		HasDescription: g.HasDescription,
		HasCover:       g.HasCover,
		Description:    g.Description,
		SHA1:           g.SHA1,
		Actions:        s.fetchGameActions(g),
		ArtURL:         fmt.Sprintf("/art/%s/%d", g.SystemKey, g.ID),
		BackHref:       safeBackPath(r.URL.Query().Get("back")),
		Meta:           pageMeta{Title: truncate(title, 40), Sub: "game detail"},
		Now:            time.Now(),
	}
	if summary, err := s.st.SystemSummary(); err == nil {
		for _, ss := range summary {
			if ss.Key == sys {
				vm.HasReport = ss.Verify.ReportPath != ""
				break
			}
		}
	}
	s.render(w, http.StatusOK, "layout-game", vm)
}

// gamePill renders the per-game verify pill — the card-wall indicator's
// little sibling: green verified / red unmatched / grey unknown (the
// system-level amber states live on reports, never on game rows).
func gamePill(state string) template.HTML {
	switch state {
	case verifyStateVerified:
		return `<span class="pill ok" title="claimed by the last DAT verify">verified</span>`
	case verifyStateUnmatched:
		return `<span class="pill stale" title="not claimed by the DAT — see Verify">unmatched</span>`
	default:
		return `<span class="pill unknown" title="never verified">unknown</span>`
	}
}
