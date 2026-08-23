package exo

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// openTemp opens a throwaway store (the store tests' pattern, local so
// this package stays independent).
func openTemp(t *testing.T) *store.Store {
	t.Helper()
	s, err := store.Open(filepath.Join(t.TempDir(), "exo.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() }) //nolint:errcheck // test
	return s
}

// samplePath resolves the committed fixture that mirrors real
// exo-to-pegasus.py output (header comments, launch line, per-game
// enrichment, assets.box_front, x-lb-id/x-manual/x-favorite extras).
func samplePath(t *testing.T) string {
	t.Helper()
	p := filepath.Join("..", "..", "testdata", "exo-dos-sample.pegasus.txt")
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("committed sample missing: %v", err)
	}
	return p
}

// stageSample materializes <root>/exo-dos/metadata.pegasus.txt from the
// committed sample and returns the root.
func stageSample(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	dir := filepath.Join(root, "exo-dos")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(samplePath(t))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "metadata.pegasus.txt"), b, 0o644); err != nil {
		t.Fatal(err)
	}
	return root
}

// TestImportFixtureEndToEnd runs the committed sample through Import and
// asserts every surface the webapp gains: a source=exo system row, game
// rows keyed by conf path, verbatim enrichment, genre joining, cover
// flags, curation preservation across re-import, and catalogue-rescan
// coexistence.
func TestImportFixtureEndToEnd(t *testing.T) {
	s := openTemp(t)
	root := stageSample(t)

	// A catalogue system already in the table: rescans must never disturb
	// it, and it must not disturb the import.
	if err := s.UpsertSystems([]store.SystemRow{
		{Key: "nes", Collection: "Nintendo Entertainment System", Bucket: "cartridge", SortOrder: 1},
	}); err != nil {
		t.Fatal(err)
	}

	res := Import(s, root)
	if len(res.Warnings) != 0 {
		t.Fatalf("clean import produced warnings: %v", res.Warnings)
	}
	if len(res.Imported) != 1 || res.Imported[0] != "dos" {
		t.Fatalf("imported = %v, want [dos]", res.Imported)
	}
	if res.Games != 6 || res.Art != 5 {
		t.Fatalf("counts = games %d art %d, want 6/5", res.Games, res.Art)
	}
	// win3x/win9x absent from this root: skipped silently.
	if len(res.Skipped) != 2 {
		t.Fatalf("skipped = %v, want [win3x win9x]", res.Skipped)
	}

	sys, err := s.System("dos")
	if err != nil || sys == nil {
		t.Fatalf("dos system missing: %v", err)
	}
	if sys.Source != store.SourceExo || sys.Bucket != store.ExoBucket || sys.Collection != "eXoDOS" {
		t.Fatalf("system row wrong: %+v", sys)
	}

	// Browse: ListGames finds an eXo title by prefix; the enrichment view
	// (SystemGamesWithMeta) carries the verbatim ingested description.
	page, err := s.ListGames(store.GameListOpts{SystemKey: "dos", Q: "Lighthouse"})
	if err != nil || len(page.Games) != 1 {
		t.Fatalf("browse search = %+v, %v", page, err)
	}
	g := page.Games[0]
	detail, err := s.GetGame("dos", g.ID)
	if err != nil || detail == nil {
		t.Fatal(err)
	}
	if detail.System.Source != store.SourceExo {
		t.Fatalf("detail system source = %q", detail.System.Source)
	}

	// Genre joining + description verbatim, through the enrichment view.
	page2, _ := s.ListGames(store.GameListOpts{SystemKey: "dos", Q: "Tractor"})
	if len(page2.Games) != 1 {
		t.Fatalf("tractor search = %+v", page2)
	}
	var tractor, lighthouse store.GameMetaRow
	rows, _ := s.SystemGamesWithMeta("dos") // visible-only view the generator WOULD read if it didn't skip exo
	for _, r := range rows {
		switch {
		case strings.HasPrefix(r.RelPath, "!dos/TurboTrk"):
			tractor = r
		case strings.HasPrefix(r.RelPath, "!dos/LhouseK"):
			lighthouse = r
		}
	}
	if tractor.Genre != "Racing; Sports" {
		t.Fatalf("genre join = %q, want %q", tractor.Genre, "Racing; Sports")
	}
	wantDesc := "Keep the lamps lit, decode the weather wire, and unravel the cove's oldest mystery."
	if lighthouse.Description != wantDesc {
		t.Fatalf("description = %q", lighthouse.Description)
	}

	// Cover flags: exactly the five box_front carriers.
	stats, _ := s.ExoStatsBySystem()
	if stats["dos"].Games != 6 || stats["dos"].Art != 5 {
		t.Fatalf("stats = %+v, want {6 5}", stats["dos"])
	}

	// Curation survives re-import: hide a game, re-run Import, hidden stays.
	if err := s.SetGameHidden("dos", "!dos/Cipher38/dosbox.conf", true); err != nil {
		t.Fatal(err)
	}
	Import(s, root)
	pg, _ := s.ListGames(store.GameListOpts{SystemKey: "dos"})
	hiddenKept := false
	for _, gg := range pg.Games {
		if gg.RelPath == "!dos/Cipher38/dosbox.conf" && gg.Hidden {
			hiddenKept = true
		}
	}
	if !hiddenKept {
		t.Fatal("re-import lost the hidden flag")
	}

	// Catalogue rescan coexistence: UpsertSystems prunes nothing exo.
	if err := s.UpsertSystems([]store.SystemRow{
		{Key: "nes", Collection: "Nintendo Entertainment System", Bucket: "cartridge", SortOrder: 1},
	}); err != nil {
		t.Fatal(err)
	}
	if sys2, _ := s.System("dos"); sys2 == nil {
		t.Fatal("catalogue rescan pruned the exo system")
	}
}

// TestImportAbsentAndBrokenRoots: no metadata files → everything skipped,
// zero rows created; a corrupt file warns and keeps previous rows.
func TestImportAbsentAndBrokenRoots(t *testing.T) {
	s := openTemp(t)

	res := Import(s, t.TempDir())
	if len(res.Imported) != 0 || res.Games != 0 || len(res.Skipped) != len(Collections) {
		t.Fatalf("absent root import = %+v", res)
	}
	systems, _ := s.Systems()
	if len(systems) != 0 {
		t.Fatalf("absent import created rows: %+v", systems)
	}

	// Broken file: warning recorded, nothing imported, no crash.
	root := t.TempDir()
	dir := filepath.Join(root, "exo-dos")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "metadata.pegasus.txt"), []byte("not pegasus at all\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	res = Import(s, root)
	if len(res.Warnings) == 0 {
		t.Fatal("corrupt metadata imported without a warning")
	}
	if len(res.Imported) != 0 {
		t.Fatalf("corrupt metadata reported as imported: %+v", res)
	}
}

// TestEmptyRootConfigured: empty-string root is a no-op (module option
// unset), never a panic or a walk of "".
func TestEmptyRootConfigured(t *testing.T) {
	s := openTemp(t)
	res := Import(s, "")
	if len(res.Imported)+len(res.Skipped)+len(res.Warnings) != 0 {
		t.Fatalf("empty root produced results: %+v", res)
	}
}
