// Package web serves the Zeus-styled dashboard: pool health with why-down
// reasons, the onboarding/keys pages, and the event log. Server-rendered
// Go templates; CSS consumes var(--ze-*) tokens only.
package web

import (
	"embed"
	"fmt"
	"html/template"
	"net/http"
	"time"

	"modelrouter/internal/health"
	"modelrouter/internal/ledger"
	"modelrouter/internal/pool"
	"modelrouter/internal/seed"
	"modelrouter/internal/vault"
)

//go:embed templates/*.gohtml
var tmplFS embed.FS

//go:embed static/zeus-tokens.css static/app.css
var staticFS embed.FS

// Server assembles dashboard state.
type Server struct {
	Pools   *pool.Pool
	Machine *health.Machine
	Ledger  *ledger.Ledger
	Seed    seed.Seed
	Vault   *vault.Vault
	Events  func(limit int) []health.Event
	SaveKey func(providerID, key string) error // vault.Put + validate
}

// NewServer builds the dashboard server.
func NewServer(p *pool.Pool, m *health.Machine, led *ledger.Ledger, s seed.Seed, v *vault.Vault, eventsFn func(int) []health.Event, saveKey func(string, string) error) *Server {
	return &Server{Pools: p, Machine: m, Ledger: led, Seed: s, Vault: v, Events: eventsFn, SaveKey: saveKey}
}

// Mux assembles the routes.
func (s *Server) Mux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /static/", func(w http.ResponseWriter, r *http.Request) {
		name := r.URL.Path[len("/static/"):]
		b, err := staticFS.ReadFile("static/" + name)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		ct := "text/css"
		w.Header().Set("Content-Type", ct)
		w.Write(b)
	})
	mux.HandleFunc("GET /", s.handleDashboard)
	mux.HandleFunc("GET /keys", s.handleKeys)
	mux.HandleFunc("POST /keys/{id}", s.handleKeySave)
	mux.HandleFunc("GET /events", s.handleEvents)
	return mux
}

func (s *Server) render(w http.ResponseWriter, page string, data any) {
	t, err := template.ParseFS(tmplFS, "templates/"+page, "templates/layout-share.gohtml")
	if err == nil {
		// the layout define lives in each page file; ParseFS with both works
		// because content is redefined per page
	}
	// simpler: parse the page file alone — each embeds its own layout
	t, err = template.ParseFS(tmplFS, "templates/"+page)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	if err := t.ExecuteTemplate(w, "layout", data); err != nil {
		http.Error(w, err.Error(), 500)
	}
}

type poolView struct {
	Family        string
	State         string
	StateLabel    string
	EndpointCount int
	InFlight      int
	Endpoints     []endpointView
}

type endpointView struct {
	Provider string
	WhyDown  string
}

func (s *Server) handleDashboard(w http.ResponseWriter, r *http.Request) {
	families := s.familyList()
	var pools []poolView
	for _, fam := range families {
		members := s.Pools.Members(fam)
		pv := poolView{Family: fam, State: "ok", StateLabel: "healthy", EndpointCount: len(members)}
		anyDown := false
		for _, e := range members {
			ev := endpointView{Provider: e.Scope.Provider}
			if blocked, why, _ := s.Machine.Blocks(e.Scope); blocked {
				ev.WhyDown = why
				anyDown = true
			}
			pv.Endpoints = append(pv.Endpoints, ev)
		}
		if anyDown && len(pv.Endpoints) > 0 {
			allDown := true
			for _, e := range pv.Endpoints {
				if e.WhyDown == "" {
					allDown = false
					break
				}
			}
			if allDown {
				pv.State, pv.StateLabel = "alert", "all down"
			} else {
				pv.State, pv.StateLabel = "warn", "degraded"
			}
		}
		pools = append(pools, pv)
	}
	s.render(w, "dashboard.gohtml", map[string]any{"Pools": pools, "Families": families})
}

func (s *Server) familyList() []string {
	seen := make(map[string]bool)
	for _, m := range s.Seed.Models {
		if m.Status == "free" || m.Status == "free_capped" || m.Status == "trial" {
			seen[m.Family] = true
		}
	}
	out := make([]string, 0, len(seen))
	for f := range seen {
		out = append(out, f)
	}
	return out
}

type providerView struct {
	ID         string
	Name       string
	SignupURL  string
	KeyPageURL string
	Friction   string
	KeyChip    string
	KeyState   string
	Detail     string
}

func (s *Server) handleKeys(w http.ResponseWriter, r *http.Request) {
	var providers []providerView
	for _, p := range s.Seed.Providers {
		pv := providerView{ID: p.ID, Name: p.Name, SignupURL: p.SignupURL, KeyPageURL: p.KeyPageURL}
		if len(p.FrictionFlags) > 0 {
			f := ""
			for i, ff := range p.FrictionFlags {
				if i > 0 {
					f += "; "
				}
				f += ff
			}
			pv.Friction = f
		}
		if s.Vault != nil {
			st, err := s.Vault.Status(p.ID)
			if err == nil {
				pv.KeyState = string(st.State)
				switch st.State {
				case vault.Valid:
					pv.KeyChip = "ok"
				case vault.Invalid:
					pv.KeyChip = "alert"
					pv.Detail = st.Detail
				case vault.KeyState("validating"):
					pv.KeyChip = "info"
				default:
					pv.KeyChip = "muted"
				}
			}
		}
		providers = append(providers, pv)
	}
	s.render(w, "keys.gohtml", map[string]any{"Providers": providers})
}

func (s *Server) handleKeySave(w http.ResponseWriter, r *http.Request) {
	providerID := r.PathValue("id")
	key := r.PostFormValue("key")
	if key == "" {
		http.Redirect(w, r, "/keys", http.StatusSeeOther)
		return
	}
	if s.SaveKey != nil {
		if err := s.SaveKey(providerID, key); err != nil {
			http.Error(w, "save failed: "+err.Error(), http.StatusInternalServerError)
			return
		}
	}
	http.Redirect(w, r, "/keys", http.StatusSeeOther)
}

type eventView struct {
	Time     string
	Provider string
	Model    string
	Kind     string
	Reason   string
}

func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request) {
	var events []eventView
	if s.Events != nil {
		for _, ev := range s.Events(100) {
			events = append(events, eventView{
				Time:     ev.Time.Format(time.RFC3339),
				Provider: ev.Scope.Provider,
				Model:    ev.Scope.Model,
				Kind:     ev.Kind,
				Reason:   ev.Reason,
			})
		}
	}
	s.render(w, "events.gohtml", map[string]any{"Events": events})
}

var _ = fmt.Sprintf // silence unused-import churn during wiring
