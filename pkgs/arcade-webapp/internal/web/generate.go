// Launcher-DB generation UI + triggers (gauntlet P6, goal 5): the
// manual "Regenerate" action on the metadata page, the generation log
// section, and the automatic regeneration after a successful verify
// (promotions changed the served trees — the kiosks must see them).
//
// POST /generate is synchronous by design: generation is a bounded
// local job (no network, no child processes), so by the time the
// handler answers 200 the runs table ALREADY carries the outcome the
// refreshed fragment renders. Serialization rides the shared pipeline
// mutex inside generate.Generator (ADV-P5-03 family): a second click
// while one runs — or while a verify/scrape holds the slot — is a
// deterministic 409. Curation hooks (P7) call Generator.Generate(dryRun)
// directly; the dry-run flag exists for their diff-preview flow.
package web

import (
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"strings"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/generate"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/igir"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// WithGenerator wires the P6 launcher-DB generator (nil = the page
// renders its "not configured" state and /generate answers 503).
func WithGenerator(g *generate.Generator) Option {
	return func(s *Server) { s.gen = g }
}

// handleGenerate regenerates every populated system's metadata file now
// and answers with the refreshed metadata fragment (the button swaps
// #metadata-panel, so the new generation log row is the response).
func (s *Server) handleGenerate(w http.ResponseWriter, r *http.Request) {
	if !hxRequestOK(r) {
		http.Error(w, "htmx requests only", http.StatusForbidden)
		return
	}
	if s.gen == nil || !s.gen.Configured() {
		http.Error(w, "generator not configured", http.StatusServiceUnavailable)
		return
	}
	res, err := s.gen.Generate(false)
	if errors.Is(err, generate.ErrBusy) {
		http.Error(w, "a pipeline job holds the slot (verify/scrape/generate)", http.StatusConflict)
		return
	}
	if err != nil {
		log.Printf("web: generate: %v", err)
		http.Error(w, "generation could not be started", http.StatusInternalServerError)
		return
	}
	vm := s.fetchMetadata()
	if !res.Validated {
		vm.Error = "some systems failed generation — see the launcher DB log (their previous files stay served)"
	}
	s.render(w, http.StatusOK, "partial-metadata", vm)
}

// maybeGenerateAfterVerify is the post-successful-verify trigger point:
// promotions just changed the games trees, so the launcher DB must
// follow before any kiosk re-reads it. Best-effort and logged — a
// failed regeneration never fails the verify that caused it (the
// operator can always click Regenerate). Runs in the caller's
// background goroutine; the runner has released the pipeline slot by
// the time Verify returns, so the generator can claim it here.
func (s *Server) maybeGenerateAfterVerify(outcomes []igir.SystemOutcome, verifyErr error) {
	if verifyErr != nil || s.gen == nil || !s.gen.Configured() {
		return
	}
	promoted := false
	for _, oc := range outcomes {
		if oc.Outcome == igir.OutcomeVerified || oc.Outcome == igir.OutcomePromotedUnchecked {
			promoted = true
			break
		}
	}
	if !promoted {
		return // skipped-empty/failed batches changed no tree
	}
	if _, err := s.gen.Generate(false); err != nil {
		log.Printf("web: post-verify regeneration: %v", err)
		return
	}
	log.Printf("web: post-verify regeneration complete")
}

// ---- generation log view model ---------------------------------------------

// genLogVM backs the metadata page's "Launcher database" section: the
// Regenerate affordance plus the recent kind=generate runs (the durable
// record; generation is synchronous so there is no live-progress state
// to poll).
const genLogRuns = 6

type genLogVM struct {
	Configured bool
	Last       *store.Run // newest generate run (nil = never)
	Runs       []store.Run
}

func (s *Server) fetchGenLog() genLogVM {
	vm := genLogVM{Configured: s.gen != nil && s.gen.Configured()}
	if !vm.Configured {
		return vm
	}
	runs, err := s.st.RunsByKind("generate", genLogRuns)
	if err != nil {
		log.Printf("web: generation log: %v", err)
		return vm // degrade to an empty log, never a broken page
	}
	vm.Runs = runs
	if len(runs) > 0 {
		vm.Last = &runs[0]
	}
	return vm
}

// ---- run detail rendering ---------------------------------------------------

// generateRunDetail mirrors the generator's runs.detail JSON.
type generateRunDetail struct {
	Systems []struct {
		Sys     string `json:"Sys"`
		Outcome string `json:"Outcome"`
		Err     string `json:"Err,omitempty"`
		Games   int    `json:"Games"`
		Pending int    `json:"Pending"`
	} `json:"Systems"`
	Validated bool `json:"Validated"`
	DryRun    bool `json:"DryRun"`
}

// generateRunDetailHTML renders the humanized detail cell for
// kind=generate runs (one line per system, capped; validation verdict;
// never raw JSON — ADV-P1-05).
func generateRunDetailHTML(detail string) (template.HTML, bool) {
	var d generateRunDetail
	if err := json.Unmarshal([]byte(detail), &d); err != nil {
		return "", false
	}
	esc := template.HTMLEscapeString
	var b strings.Builder
	head := "validated"
	if !d.Validated {
		head = "VALIDATION FAILED"
	}
	if d.DryRun {
		head += " · dry-run"
	}
	b.WriteString(esc(head))
	for i, oc := range d.Systems {
		if i >= 4 {
			fmt.Fprintf(&b, "<br><em>(+%d more systems)</em>", len(d.Systems)-4)
			break
		}
		line := fmt.Sprintf("%s: %s · %d games", esc(oc.Sys), esc(oc.Outcome), oc.Games)
		if oc.Pending > 0 {
			line += fmt.Sprintf(" · %d pending", oc.Pending)
		}
		if oc.Err != "" {
			line += " — " + esc(truncate(oc.Err, 80))
		}
		b.WriteString("<br>" + line)
	}
	return template.HTML(b.String()), true
}
