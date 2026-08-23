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
// deterministic 409. Curation hooks (P7) call regenerateLauncherDBAsync,
// which runs the same pass in the caller's background goroutine.
package web

import (
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/generate"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/igir"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// WithGenerator wires the P6 launcher-DB generator (nil = the page
// renders its "not configured" state and /generate answers 503).
func WithGenerator(g *generate.Generator) Option {
	return func(s *Server) { s.gen = g }
}

// generateOptions assembles the generator's Options from the store:
// every custom collection with its VISIBLE members (hidden games are
// excluded by contract, so they are dropped here at the source). A read
// failure is an error, never a silent empty set — dropping collections
// silently would make the next generation un-list them from every kiosk.
func (s *Server) generateOptions() (generate.Options, error) {
	var opts generate.Options
	cols, err := s.st.Collections()
	if err != nil {
		return opts, fmt.Errorf("collections: %w", err)
	}
	for _, c := range cols {
		members, err := s.st.CollectionMembers(c.ID)
		if err != nil {
			return opts, fmt.Errorf("collection %d members: %w", c.ID, err)
		}
		gc := generate.CustomCollection{
			Title:     c.Name,
			Shortname: c.Shortname,
			Summary:   c.Summary,
		}
		for _, m := range members {
			if m.Hidden {
				continue // hidden games never reach generation
			}
			gc.Members = append(gc.Members, generate.CollectionMember{
				SystemKey: m.SystemKey, RelPath: m.RelPath,
			})
		}
		opts.CustomCollections = append(opts.CustomCollections, gc)
	}
	return opts, nil
}

// regenerationPass is ONE attempt to regenerate the launcher DB with the
// current store state (curation included), recording an explicit skipped
// run row when the pipeline slot is held. retryOnBusy schedules exactly
// one deferred retry (ADV-P6-03); a retry that finds the slot busy again
// stays the accepted D-P6d residual. Callers run it in their own
// goroutine when they must not block.
func (s *Server) regenerationPass(retryOnBusy bool) {
	if s.gen == nil || !s.gen.Configured() {
		return
	}
	opts, err := s.generateOptions()
	if err != nil {
		log.Printf("web: regeneration options: %v", err)
		return
	}
	if _, err := s.gen.GenerateOptions(false, opts); err != nil {
		if !errors.Is(err, generate.ErrBusy) {
			log.Printf("web: regeneration: %v", err)
			return
		}
		s.recordGenerateSkip()
		if retryOnBusy {
			time.AfterFunc(postVerifyRetryDelay, func() { s.regenerationPass(false) })
		}
		return
	}
	log.Printf("web: regeneration complete")
}

// regenerateLauncherDBAsync fires one regenerationPass in the background
// — the hide/unhide/collection-edit trigger (P7): a cheap DB write must
// never wait on the heavy job it causes, and the operator sees the
// result land via the generation log / served tree within seconds.
func (s *Server) regenerateLauncherDBAsync() {
	go s.regenerationPass(true)
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
	opts, err := s.generateOptions()
	if err != nil {
		log.Printf("web: generate: %v", err)
		http.Error(w, "generation could not be started", http.StatusInternalServerError)
		return
	}
	res, err := s.gen.GenerateOptions(false, opts)
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
	s.regenerationPass(true)
}

// postVerifyRetryDelay is the single deferred-retry window for a
// regeneration that found the pipeline slot busy (ADV-P6-03). A var so
// tests can shrink it.
var postVerifyRetryDelay = 30 * time.Second

// recordGenerateSkip leaves the visible history marker for a skipped
// post-verify regeneration: silence would read as "nothing needed
// regenerating", which is exactly the lie this row prevents.
func (s *Server) recordGenerateSkip() {
	id, err := s.st.StartRun("generate")
	if err != nil {
		log.Printf("web: record generate skip: %v", err)
		return
	}
	if err := s.st.FinishRun(id, "skipped", "post-verify regeneration skipped (pipeline busy)"); err != nil {
		log.Printf("web: record generate skip: %v", err)
	}
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
		Sys         string `json:"Sys"`
		Outcome     string `json:"Outcome"`
		Err         string `json:"Err,omitempty"`
		Games       int    `json:"Games"`
		Pending     int    `json:"Pending"`
		Collections int    `json:"Collections"`
	} `json:"Systems"`
	Validated bool `json:"Validated"`
	DryRun    bool `json:"DryRun"`
}

// generateRunDetailHTML renders the humanized detail cell for
// kind=generate runs (one line per system, capped; validation verdict;
// never raw JSON — ADV-P1-05). Collection counts (P7) ride each system
// line plus the head total.
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
	totalCols := 0
	for _, oc := range d.Systems {
		totalCols += oc.Collections
	}
	if totalCols > 0 {
		head += fmt.Sprintf(" · %d custom collection block(s)", totalCols)
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
		if oc.Collections > 0 {
			line += fmt.Sprintf(" · %d collections", oc.Collections)
		}
		if oc.Err != "" {
			line += " — " + esc(truncate(oc.Err, 80))
		}
		b.WriteString("<br>" + line)
	}
	return template.HTML(b.String()), true
}
