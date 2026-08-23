// Custom-collections UI (gauntlet P7, goal 6): operator-defined,
// cross-system game sets — RomM-parity curation whose feedback loop is
// the win condition: an edit lands in the served launcher tree within
// seconds (the generator emits each collection as a first-class Pegasus
// block in EVERY member system's file).
//
// This file carries:
//   - GET /collections (+ its htmx fragment): the list — name, derived
//     stable shortname, member count — and the create form.
//   - GET /collections/{id}: the editor — rename/re-summary, the member
//     table with remove buttons, and an add-by-search box over the same
//     ListGames q filter the library grid uses.
//   - POST create/update/delete/add/remove: all mutating endpoints are
//     htmx-only (D-P2c). Every membership/identity edit triggers one
//     asynchronous launcher-DB regeneration through
//     requestRegeneration (creation does not — a brand-new empty
//     collection is provably output-neutral, so there is nothing to
//     regenerate yet).
package web

import (
	"errors"
	"fmt"
	"log"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/generate"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// colSearchLimit caps the editor's add-box result list.
const colSearchLimit = 8

// ---- view models -----------------------------------------------------------

type collectionCardVM struct {
	ID         int64
	Name       string
	Shortname  string
	Summary    string
	Games      int64
	UpdatedAgo string
}

type collectionsVM struct {
	Collections []collectionCardVM
	Error       string
	// RegenAlert is the visible warning when the last automatic
	// launcher-DB regeneration failed (ADV-P7-01b) — without it a failed
	// async pass lived only in journal+run rows. "" = healthy.
	RegenAlert string
	Meta       pageMeta
	Now        time.Time
}

type collectionMemberVM struct {
	GameID    int64
	SystemKey string
	Title     string
	Hidden    bool // excluded from generation while hidden (chip explains why)
	Pending   bool // fails the completeness sniff: listed-not-launchable (chip)
}

type collectionSearchVM struct {
	GameID    int64
	SystemKey string
	Title     string
}

type collectionEditorVM struct {
	Collection store.CollectionRow
	UpdatedAgo string
	Members    []collectionMemberVM
	// Honest member counts (P7-critic carry-in, built with P8): Tracked
	// is every member; Playable is the subset that will reach the kiosk
	// as launchable (visible AND complete). Sniffable reports whether the
	// games roots are wired — without them playability cannot be sniffed,
	// so the header degrades to "N tracked" rather than guessing.
	Tracked, Playable int
	Sniffable         bool
	Q                 string
	Results           []collectionSearchVM
	Error             string
	RegenAlert        string // last failed regeneration marker (ADV-P7-01b); "" = healthy
	Meta              pageMeta
	Now               time.Time
}

func collectionsPageMeta() pageMeta {
	return pageMeta{Title: "collections", Sub: "custom collections", ActiveCollections: true}
}

func cardOf(c store.CollectionRow, now time.Time) collectionCardVM {
	vm := collectionCardVM{
		ID: c.ID, Name: c.Name, Shortname: c.Shortname,
		Summary: c.Summary, Games: c.Games,
	}
	if c.UpdatedAt != "" {
		vm.UpdatedAgo = relTime(now, c.UpdatedAt)
	}
	return vm
}

// fetchCollections assembles the list page's view model.
func (s *Server) fetchCollections() collectionsVM {
	vm := collectionsVM{Meta: collectionsPageMeta(), Now: time.Now(), RegenAlert: s.regenAlert()}
	cols, err := s.st.Collections()
	if err != nil {
		log.Printf("web: collections: %v", err)
		vm.Error = "collections unavailable"
		return vm
	}
	for _, c := range cols {
		vm.Collections = append(vm.Collections, cardOf(c, vm.Now))
	}
	return vm
}

// editorStatus distinguishes why fetchCollectionEditor stopped.
type editorStatus int

const (
	editorOK     editorStatus = iota // vm usable
	editorAbsent                     // no such collection id
	editorFailed                     // store error surfaced in vm.Error
)

// fetchCollectionEditor assembles the editor page: members plus (when q
// is set) non-member search candidates. Read failures degrade to an
// emptier page with the error surfaced, never a 500 wall.
func (s *Server) fetchCollectionEditor(r *http.Request, id int64) (collectionEditorVM, editorStatus) {
	vm := collectionEditorVM{
		Meta:       pageMeta{Title: "collection", Sub: "custom collections", ActiveCollections: true},
		Now:        time.Now(),
		RegenAlert: s.regenAlert(),
	}
	col, err := s.st.Collection(id)
	if err != nil {
		log.Printf("web: collection %d: %v", id, err)
		return vm, editorFailed
	}
	if col == nil {
		return vm, editorAbsent
	}
	vm.Collection = *col
	if col.UpdatedAt != "" {
		vm.UpdatedAgo = relTime(vm.Now, col.UpdatedAt)
	}
	// The pending sniff needs each member's file under its system's
	// bucket root; the buckets come from the systems table (the catalogue
	// copy the scanner upserts).
	buckets := map[string]string{}
	if systems, err := s.st.Systems(); err == nil {
		for _, sys := range systems {
			buckets[sys.Key] = sys.Bucket
		}
	} else {
		log.Printf("web: collection %d systems: %v", id, err) // degrade: no pending chips
	}
	sniffable := s.gameRoots != gameRoots{}
	members, err := s.st.CollectionMembers(id)
	if err != nil {
		log.Printf("web: collection %d members: %v", id, err)
		vm.Error = "members unavailable"
		return vm, editorOK
	}
	memberIDs := map[int64]bool{}
	for _, m := range members {
		memberIDs[m.GameID] = true
		pending := false
		if root := s.gameRoots.forBucket(buckets[m.SystemKey]); root != "" {
			pending = !generate.RomComplete(filepath.Join(root, m.SystemKey, m.RelPath))
		}
		vm.Members = append(vm.Members, collectionMemberVM{
			GameID: m.GameID, SystemKey: m.SystemKey,
			Title: displayTitle(m.Title, m.RelPath), Hidden: m.Hidden, Pending: pending,
		})
		vm.Tracked++
		if !m.Hidden && !pending {
			vm.Playable++
		}
	}
	vm.Sniffable = sniffable

	vm.Q = strings.TrimSpace(r.URL.Query().Get("q"))
	if len([]rune(vm.Q)) > 100 {
		vm.Q = string([]rune(vm.Q)[:100])
	}
	if vm.Q != "" {
		pg, err := s.st.ListGames(store.GameListOpts{Q: vm.Q, Limit: colSearchLimit + len(memberIDs)})
		if err != nil {
			log.Printf("web: collection %d search: %v", id, err)
			vm.Error = "search unavailable"
			return vm, editorOK
		}
		for _, g := range pg.Games {
			if memberIDs[g.ID] {
				continue
			}
			vm.Results = append(vm.Results, collectionSearchVM{
				GameID: g.ID, SystemKey: g.SystemKey, Title: displayTitle(g.Title, g.RelPath),
			})
			if len(vm.Results) >= colSearchLimit {
				break
			}
		}
	}
	return vm, editorOK
}

// ---- handlers ---------------------------------------------------------------

func (s *Server) handleCollectionsPage(w http.ResponseWriter, _ *http.Request) {
	vm := s.fetchCollections()
	s.render(w, http.StatusOK, "layout-collections", vm)
}

func (s *Server) handlePartialCollections(w http.ResponseWriter, _ *http.Request) {
	vm := s.fetchCollections()
	s.render(w, http.StatusOK, "partial-collections", vm)
}

func (s *Server) handleCollectionPage(w http.ResponseWriter, r *http.Request) {
	id, ok := parseCollectionID(w, r)
	if !ok {
		return
	}
	vm, st := s.fetchCollectionEditor(r, id)
	switch st {
	case editorOK:
		s.render(w, http.StatusOK, "layout-collection", vm)
	case editorAbsent:
		http.NotFound(w, r)
	default:
		http.Error(w, "collection lookup failed", http.StatusInternalServerError)
	}
}

// renderCollectionEditor is the shared POST answer: re-render the
// editor fragment (404 when the collection vanished mid-action).
func (s *Server) renderCollectionEditor(w http.ResponseWriter, r *http.Request, id int64) {
	vm, st := s.fetchCollectionEditor(r, id)
	switch st {
	case editorOK:
		s.render(w, http.StatusOK, "partial-collection", vm)
	case editorAbsent:
		http.NotFound(w, r)
	default:
		http.Error(w, "collection lookup failed", http.StatusInternalServerError)
	}
}

// parseCollectionID resolves {id}; malformed ids read as absent (404),
// never 500 — the game-detail handler's convention.
func parseCollectionID(w http.ResponseWriter, r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		http.NotFound(w, r)
		return 0, false
	}
	return id, true
}

// requireHX is the shared CSRF gate + error shape for collection POSTs.
func (s *Server) requireHX(w http.ResponseWriter, r *http.Request) bool {
	if !hxRequestOK(r) {
		http.Error(w, "htmx requests only", http.StatusForbidden)
		return false
	}
	return true
}

// reservedShortnameMessage renders the store's collision error for the
// operator, NAMING the colliding identity (ADV-P7-01) — a bare "invalid
// name" would send them hunting through the catalogue TSV.
func reservedShortnameMessage(e *store.ReservedShortnameError) string {
	what := fmt.Sprintf("catalogue system %q", e.SystemKey)
	if e.Pending {
		what = fmt.Sprintf("the pending section of catalogue system %q", e.SystemKey)
	}
	return fmt.Sprintf("the name %q derives the launcher-DB identity %q, which belongs to %s — choose another name.",
		e.Name, e.Shortname, what)
}

// handleCollectionCreate inserts a collection (shortname derived once by
// the store) and answers the refreshed list panel. No regeneration: a
// new collection has zero members, so the served trees cannot change.
// A name deriving a catalogue identity answers 409 with the collision
// named (ADV-P7-01) — never a success-shaped 200; the page's htmx-config
// swaps 409 bodies so the inline error is visible to the operator too.
func (s *Server) handleCollectionCreate(w http.ResponseWriter, r *http.Request) {
	if !s.requireHX(w, r) {
		return
	}
	name := strings.TrimSpace(r.FormValue("name"))
	if name == "" {
		vm := s.fetchCollections()
		vm.Error = "a collection needs a name."
		s.render(w, http.StatusOK, "partial-collections", vm)
		return
	}
	if _, err := s.st.CreateCollection(name, r.FormValue("summary")); err != nil {
		log.Printf("web: collection create %q: %v", name, err)
		vm := s.fetchCollections()
		var rerr *store.ReservedShortnameError
		if errors.As(err, &rerr) {
			vm.Error = reservedShortnameMessage(rerr)
			s.render(w, http.StatusConflict, "partial-collections", vm)
			return
		}
		vm.Error = "could not create the collection."
		s.render(w, http.StatusOK, "partial-collections", vm)
		return
	}
	log.Printf("web: collection %q created", name)
	vm := s.fetchCollections()
	s.render(w, http.StatusOK, "partial-collections", vm)
}

// handleCollectionUpdate renames / re-summaries one collection. The
// shortname deliberately stays (it is the block identity across the
// generated files); the regeneration refreshes name/summary everywhere.
// A rename onto a catalogue-derived identity answers 409 like a create
// (ADV-P7-01).
func (s *Server) handleCollectionUpdate(w http.ResponseWriter, r *http.Request) {
	if !s.requireHX(w, r) {
		return
	}
	id, ok := parseCollectionID(w, r)
	if !ok {
		return
	}
	name := strings.TrimSpace(r.FormValue("name"))
	if name == "" {
		vm, _ := s.fetchCollectionEditor(r, id)
		vm.Error = "a collection needs a name."
		s.render(w, http.StatusOK, "partial-collection", vm)
		return
	}
	if err := s.st.UpdateCollection(id, name, r.FormValue("summary")); err != nil {
		log.Printf("web: collection %d update: %v", id, err)
		var rerr *store.ReservedShortnameError
		if errors.As(err, &rerr) {
			vm, _ := s.fetchCollectionEditor(r, id)
			vm.Error = reservedShortnameMessage(rerr)
			s.render(w, http.StatusConflict, "partial-collection", vm)
			return
		}
		http.Error(w, "update failed", http.StatusInternalServerError)
		return
	}
	s.requestRegeneration(regenOriginCuration)
	s.renderCollectionEditor(w, r, id)
}

// handleCollectionDelete removes one collection (memberships cascade)
// and answers the refreshed list panel. Regeneration is REQUIRED here —
// the deleted block must vanish from every member system's file.
func (s *Server) handleCollectionDelete(w http.ResponseWriter, r *http.Request) {
	if !s.requireHX(w, r) {
		return
	}
	id, ok := parseCollectionID(w, r)
	if !ok {
		return
	}
	col, err := s.st.Collection(id)
	if err != nil {
		http.Error(w, "collection lookup failed", http.StatusInternalServerError)
		return
	}
	if col == nil {
		http.NotFound(w, r)
		return
	}
	if err := s.st.DeleteCollection(id); err != nil {
		log.Printf("web: collection %d delete: %v", id, err)
		http.Error(w, "delete failed", http.StatusInternalServerError)
		return
	}
	log.Printf("web: collection %q deleted; regenerating launcher DB", col.Name)
	s.requestRegeneration(regenOriginCuration)
	vm := s.fetchCollections()
	s.render(w, http.StatusOK, "partial-collections", vm)
}

// handleCollectionAddGame adds one (system, game) pair to the
// collection; the store enforces the identity pair and idempotence. The
// parameters ride the hx-post URL (?system=&game=) — r.FormValue reads
// them without any client-side JSON quoting.
func (s *Server) handleCollectionAddGame(w http.ResponseWriter, r *http.Request) {
	if !s.requireHX(w, r) {
		return
	}
	id, ok := parseCollectionID(w, r)
	if !ok {
		return
	}
	sys, gid, ok := parseGameParam(w, r)
	if !ok {
		return
	}
	if err := s.st.AddCollectionGame(id, sys, gid); err != nil {
		log.Printf("web: collection %d add %s/%d: %v", id, sys, gid, err)
		vm, _ := s.fetchCollectionEditor(r, id)
		vm.Error = "could not add that game."
		s.render(w, http.StatusOK, "partial-collection", vm)
		return
	}
	s.requestRegeneration(regenOriginCuration)
	s.renderCollectionEditor(w, r, id)
}

// handleCollectionRemoveGame drops one membership; removing a non-member
// is a no-op (store contract), so the panel just refreshes either way.
func (s *Server) handleCollectionRemoveGame(w http.ResponseWriter, r *http.Request) {
	if !s.requireHX(w, r) {
		return
	}
	id, ok := parseCollectionID(w, r)
	if !ok {
		return
	}
	sys, gid, ok := parseGameParam(w, r)
	if !ok {
		return
	}
	if err := s.st.RemoveCollectionGame(id, sys, gid); err != nil {
		log.Printf("web: collection %d remove %s/%d: %v", id, sys, gid, err)
		http.Error(w, "remove failed", http.StatusInternalServerError)
		return
	}
	s.requestRegeneration(regenOriginCuration)
	s.renderCollectionEditor(w, r, id)
}

// parseGameParam extracts the (system, gameID) identity from query/form.
func parseGameParam(w http.ResponseWriter, r *http.Request) (string, int64, bool) {
	sys := r.FormValue("system")
	gid, err := strconv.ParseInt(r.FormValue("game"), 10, 64)
	if sys == "" || err != nil || gid <= 0 {
		http.Error(w, "need system and game parameters", http.StatusBadRequest)
		return "", 0, false
	}
	return sys, gid, true
}
