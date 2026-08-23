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
// deterministic 409.
//
// Curation triggers (P7) do NOT spawn work per click: every hide/
// collection mutation calls requestRegeneration, which sets a dirty
// flag that ONE worker goroutine drains (ADV-P7-03 — N toggles during
// a verify flood used to write N "skipped" rows plus N 30s AfterFuncs).
// The worker coalesces bursts into at most one follow-up generation,
// writes ONE accurately-labeled deferral row per busy episode, retries
// until the slot frees, and records failures for the next page render
// (ADV-P7-01b) instead of leaving them in journal+run rows only.
package web

import (
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/generate"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/igir"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// WithGenerator wires the P6 launcher-DB generator (nil = the page
// renders its "not configured" state and /generate answers 503). The
// generator's bucket roots are ALSO captured on the server: they locate
// member ROM files for the collection editor's completeness-sniff chips
// (P7-critic carry-in) — one wiring, one source of roots.
func WithGenerator(g *generate.Generator) Option {
	return func(s *Server) {
		s.gen = g
		s.gameRoots = gameRoots{
			cartridge: g.CartridgeRoot,
			optical:   g.OpticalRoot,
			modern:    g.ModernRoot,
		}
	}
}

// gameRoots are the three served games buckets (mirroring the
// generator's). Zero values = not wired: the editor then degrades to
// hidden-chips only and honest "N tracked" counts without the playable
// half (it refuses to guess playability it cannot sniff).
type gameRoots struct {
	cartridge, optical, modern string
}

func (r gameRoots) forBucket(bucket string) string {
	switch bucket {
	case "optical":
		return r.optical
	case "modern":
		return r.modern
	default:
		return r.cartridge
	}
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

// ---- the regeneration coordinator (ADV-P7-03) -------------------------------

// Provenance labels for pending regenerations — they ride the deferred
// run row's detail so history reads truthfully about WHO asked
// (post-verify keeps its own label distinct from curation's).
const (
	regenOriginCuration   = "curation edit"
	regenOriginPostVerify = "post-verify promotion"
)

// regenBusyBackoff is how long the worker waits between attempts while
// the pipeline slot is held by a verify/scrape/manual job. A var so
// tests can shrink it.
var regenBusyBackoff = 30 * time.Second

// regenCoalesceWindow is the quiet period the worker lets elapse after
// the latest request before running a pass: a rapid burst (holding a
// hide button, scripted bulk edits) arrives faster than a generation
// finishes, so claiming instantly would chain one generation per window
// (observed: 17 runs for 50 toggles). Waiting for silence collapses the
// whole burst into the NEXT pass — N rapid toggles cost 1–2
// generations, and the latency budget stays "lands within seconds".
var regenCoalesceWindow = 100 * time.Millisecond

// requestRegeneration marks the launcher DB dirty for one trigger origin
// and wakes the single worker. Cheap and non-blocking: a burst of
// mutations collapses into one dirty flag, never one goroutine per click.
func (s *Server) requestRegeneration(origin string) {
	s.regenOnce.Do(func() {
		s.regen.wake = make(chan struct{}, 1)
		go s.regenWorker()
	})
	s.regenMu.Lock()
	s.regen.dirty = true
	s.regen.lastRequestAt = time.Now()
	if s.regen.origins == nil {
		s.regen.origins = make(map[string]bool)
	}
	s.regen.origins[origin] = true
	s.regenMu.Unlock()
	select {
	case s.regen.wake <- struct{}{}:
	default: // a wake token is already pending; the loop will see dirty
	}
}

// regenWorker drains the dirty flag for the process's lifetime. Parked
// (and only started) once the first regeneration is requested.
func (s *Server) regenWorker() {
	for range s.regen.wake {
		s.drainRegen()
	}
}

// drainRegen runs generations until the tree reflects the store. The
// dirty flag is CLAIMED (cleared) before each pass — mutations landing
// mid-generation queue exactly ONE follow-up pass, and the quiet-window
// gate below keeps a sustained burst from chaining passes. A busy slot
// leaves the work dirty with one coalesced deferral row per episode and
// retries after the backoff.
func (s *Server) drainRegen() {
	for {
		s.regenMu.Lock()
		if !s.regen.dirty {
			s.regenMu.Unlock()
			return
		}
		s.regen.dirty = false
		s.regen.passActive = true
		s.regenMu.Unlock()

		if s.gen == nil || !s.gen.Configured() {
			s.regenMu.Lock()
			s.regen.passActive = false
			s.regenMu.Unlock()
			return // generator-less harness/server: nothing to regenerate with
		}

		// Quiet gate: hold the pass until the burst stops arriving, so
		// its full effect lands in ONE generation (options are read
		// after this gate AND under the slot — ADV-P7-02).
		for {
			s.regenMu.Lock()
			quiet := time.Since(s.regen.lastRequestAt) >= regenCoalesceWindow
			s.regenMu.Unlock()
			if quiet {
				break
			}
			time.Sleep(regenCoalesceWindow / 4)
		}

		s.regenMu.Lock()
		origins := make([]string, 0, len(s.regen.origins))
		for o := range s.regen.origins {
			origins = append(origins, o)
		}
		s.regen.origins = nil
		deferredRow := s.regen.deferredRow
		s.regenMu.Unlock()

		res, err := s.gen.GenerateFresh(false, s.generateOptions)
		switch {
		case errors.Is(err, generate.ErrBusy):
			s.requeueRegen(origins)
			if !deferredRow {
				s.recordRegenDeferred(origins)
			}
			s.endPass()
			s.waitForRegenSlot()
		case err != nil:
			// Options/store read failure: transient by contract — stay
			// dirty and retry rather than dropping the operator's edit.
			log.Printf("web: regeneration: %v", err)
			s.requeueRegen(origins)
			s.endPass()
			s.waitForRegenSlot()
		default:
			log.Printf("web: regeneration complete")
			alert := computeRegenAlert(res)
			s.regenMu.Lock()
			// failMsg lands under the SAME unlock that ends the pass —
			// observers of "no pass active" always see the final marker.
			s.regen.deferredRow = false // episode over: future deferrals get their own row
			s.regen.failMsg = alert
			s.regen.passActive = false
			s.regenMu.Unlock()
		}
	}
}

// endPass closes a pass that did not reach its outcome-recording branch
// (busy/failed attempts): nothing new to report, just unblock observers.
func (s *Server) endPass() {
	s.regenMu.Lock()
	s.regen.passActive = false
	s.regenMu.Unlock()
}

// requeueRegen restores the dirty flag and merges back the origins still
// awaiting their pass (plus anything requested meanwhile).
func (s *Server) requeueRegen(origins []string) {
	s.regenMu.Lock()
	defer s.regenMu.Unlock()
	s.regen.dirty = true
	if s.regen.origins == nil {
		s.regen.origins = make(map[string]bool)
	}
	for _, o := range origins {
		s.regen.origins[o] = true
	}
}

// waitForRegenSlot backs off between busy attempts, waking early when a
// new request arrives.
func (s *Server) waitForRegenSlot() {
	select {
	case <-time.After(regenBusyBackoff):
	case <-s.regen.wake:
	}
}

// recordRegenDeferred writes the episode's ONE skipped run row, labeled
// with the real reason and provenance ("regeneration deferred — pipeline
// busy", who asked) — replacing ADV-P6-03's per-click "post-verify
// regeneration skipped" rows that misattributed curation deferrals and
// flooded the history during verify windows.
func (s *Server) recordRegenDeferred(origins []string) {
	s.regenMu.Lock()
	s.regen.deferredRow = true
	s.regenMu.Unlock()
	sort.Strings(origins)
	detail := strings.Join(origins, " + ")
	if detail == "" {
		detail = "trigger"
	}
	id, err := s.st.StartRun("generate")
	if err != nil {
		log.Printf("web: record regeneration deferral: %v", err)
		return
	}
	detail += " regeneration deferred — pipeline busy"
	if err := s.st.FinishRun(id, "skipped", detail); err != nil {
		log.Printf("web: record regeneration deferral: %v", err)
	}
}

// computeRegenAlert derives the operator-facing marker from a finished
// Result ("" = healthy). Per-system failures keep the run "error" but
// return nil from GenerateFresh, so the marker checks outcomes itself.
func computeRegenAlert(res generate.Result) string {
	failed := 0
	for _, oc := range res.Systems {
		if oc.Outcome == generate.OutcomeFailed {
			failed++
		}
	}
	switch {
	case !res.Validated:
		return regenFailMarker("validation refused generated output")
	case failed > 0:
		return regenFailMarker(fmt.Sprintf("%d system(s) failed generation", failed))
	default:
		return ""
	}
}

func regenFailMarker(reason string) string {
	return fmt.Sprintf("the last automatic launcher-DB regeneration failed (%s) — recent edits may not be on the kiosks yet; the log is on Metadata → Launcher database.", reason)
}

// setRegenAlert lets the synchronous manual /generate keep the marker as
// truthful as the automatic path does.
func (s *Server) setRegenAlert(res generate.Result) {
	s.regenMu.Lock()
	s.regen.failMsg = computeRegenAlert(res)
	s.regenMu.Unlock()
}

// regenAlert returns the visible warning for the most recent FAILED
// automatic regeneration (ADV-P7-01b): without it, a failed async pass
// landed only in journal+run rows while create/hide handlers kept
// answering success. Cleared by the next fully-ok generation (automatic
// or manual). "" = healthy.
func (s *Server) regenAlert() string {
	s.regenMu.Lock()
	defer s.regenMu.Unlock()
	return s.regen.failMsg
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
	// ADV-P7-02: the manual button reads its options under the slot too —
	// a click racing the async curation worker renders post-state, never
	// overwrites it with a stale pre-click snapshot.
	res, err := s.gen.GenerateFresh(false, s.generateOptions)
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
	s.setRegenAlert(res) // the failure marker stays truthful across manual passes
	s.render(w, http.StatusOK, "partial-metadata", vm)
}

// maybeGenerateAfterVerify is the post-successful-verify trigger point:
// promotions just changed the games trees, so the launcher DB must
// follow before any kiosk re-reads it. Best-effort and logged — a
// failed regeneration never fails the verify that caused it (the
// operator can always click Regenerate). The request rides the shared
// coordinator (ADV-P7-03): enqueued under the post-verify provenance
// label, drained by the single worker once the verify's slot frees.
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
	s.requestRegeneration(regenOriginPostVerify)
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
