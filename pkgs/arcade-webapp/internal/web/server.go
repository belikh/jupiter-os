// Package web serves the jupiterOS Arcade webapp: one NixOS-native app on
// europa owning the whole cartridge-ROM pipeline (DAT currency, aria2
// downloads, igir verify, Skyscraper metadata, Pegasus launcher-DB
// generation, curation). See docs/adr/0002-arcade-webapp-custom-vs-romm.md
// and docs/plans/arcade-webapp-gauntlet.md.
//
// This is the Phase 0 stub: a placeholder front page and /healthz, structured
// so later phases grow it (dashboard, pipeline control, library, curation)
// without re-layout. Stack per ADR-0002 D4: Go stdlib net/http +
// html/template; htmx (vendored single file) and the SQLite store arrive with
// the phases that need them.
package web

import (
	"html/template"
	"net/http"
)

// pageTmpl is the stub front page. Inline for now: a full templates/
// directory arrives when real pages do (Phase 1).
var pageTmpl = template.Must(template.New("index").Parse(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>jupiterOS Arcade</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 2rem auto; max-width: 40rem; }
    code { background: #f4f4f4; padding: 0 0.25rem; }
  </style>
</head>
<body>
  <h1>jupiterOS Arcade</h1>
  <p>arcade webapp placeholder — Phase 0 stub.</p>
  <p>The pipeline dashboard, download/verify/metadata control, library
     browsing and curation land in phases 1&ndash;4 of the
     <a href="https://github.com/belikh/jupiter-os/blob/main/docs/plans/arcade-webapp-gauntlet.md">gauntlet plan</a>.</p>
  <p>Health: <code>/healthz</code></p>
</body>
</html>
`))

// Server holds the webapp's HTTP routes. The mux is built once in New so the
// handler tree is immutable per process; phase-scoped state (SQLite store,
// job queue) will hang off this struct without changing call sites.
type Server struct {
	handler http.Handler
}

// New builds the webapp's HTTP handler.
func New() *Server {
	mux := http.NewServeMux()
	s := &Server{handler: mux}
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.HandleFunc("/", s.handleIndex)
	return s
}

// Handler returns the rooted handler; main wires it into an http.Server.
func (s *Server) Handler() http.Handler { return s.handler }

func (s *Server) handleIndex(w http.ResponseWriter, r *http.Request) {
	// http.ServeMux registers "/" as a subtree match; anything not caught by
	// a more specific pattern lands here. Only the root itself is a page.
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := pageTmpl.Execute(w, nil); err != nil {
		http.Error(w, "template error", http.StatusInternalServerError)
	}
}

func (s *Server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok\n"))
}
