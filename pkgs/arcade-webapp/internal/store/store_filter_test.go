package store

import (
	"path/filepath"
	"testing"
	"time"
)

// TestListGamesMetadataFilters pins the P8.1 metadata filtering contract:
// the library can filter by scrape-coverage flags (has_description /
// has_cover) and by ingested genre — the store-side half of "filter by
// any of the metadata". Fixtures deliberately mix flag/genre shapes:
// A has both flags + genre; B has description only, no cover, no genre;
// C has neither flag nor genre (the plain catalogue-row shape).
func TestListGamesMetadataFilters(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer s.Close() //nolint:errcheck // test store

	if err := s.UpsertSystems([]SystemRow{{Key: "nes", Collection: "Nintendo", Bucket: "cartridge", SortOrder: 1}}); err != nil {
		t.Fatalf("systems: %v", err)
	}
	games := []GameRow{
		{RelPath: "A (USA).nes", SizeBytes: 10},
		{RelPath: "B (USA).nes", SizeBytes: 20},
		{RelPath: "C (USA).nes", SizeBytes: 30},
	}
	if err := s.ReplaceSystemGames("nes", games, time.Now().UTC().Truncate(time.Second)); err != nil {
		t.Fatalf("games: %v", err)
	}
	if err := s.SetSystemScrapeFlags("nes", []GameScrapeFlag{
		{RelPath: "A (USA).nes", Description: true, Cover: true},
		{RelPath: "B (USA).nes", Description: true},
	}); err != nil {
		t.Fatalf("flags: %v", err)
	}
	if err := s.SetGameMeta("nes", []GameMeta{
		{RelPath: "A (USA).nes", Genre: "Platform"},
		{RelPath: "B (USA).nes", Genre: "Puzzle"},
	}); err != nil {
		t.Fatalf("meta: %v", err)
	}

	list := func(opts GameListOpts) []string {
		t.Helper()
		pg, err := s.ListGames(opts)
		if err != nil {
			t.Fatalf("ListGames(%+v): %v", opts, err)
		}
		out := make([]string, 0, len(pg.Games))
		for _, g := range pg.Games {
			out = append(out, g.RelPath)
		}
		return out
	}
	yes, no := true, false

	// Description flag filters.
	got := list(GameListOpts{SystemKey: "nes", HasDescription: &yes})
	if len(got) != 2 || got[0] != "A (USA).nes" || got[1] != "B (USA).nes" {
		t.Errorf("has_description=yes = %v, want A+B", got)
	}
	got = list(GameListOpts{SystemKey: "nes", HasDescription: &no})
	if len(got) != 1 || got[0] != "C (USA).nes" {
		t.Errorf("has_description=no = %v, want C", got)
	}
	// Cover flag filters.
	got = list(GameListOpts{SystemKey: "nes", HasCover: &yes})
	if len(got) != 1 || got[0] != "A (USA).nes" {
		t.Errorf("has_cover=yes = %v, want A", got)
	}
	got = list(GameListOpts{SystemKey: "nes", HasCover: &no})
	if len(got) != 2 {
		t.Errorf("has_cover=no = %v, want B+C", got)
	}
	// Both flags AND: only A carries both.
	got = list(GameListOpts{SystemKey: "nes", HasDescription: &yes, HasCover: &yes})
	if len(got) != 1 || got[0] != "A (USA).nes" {
		t.Errorf("desc=yes+cover=yes = %v, want A", got)
	}
	// Genre exact match.
	got = list(GameListOpts{SystemKey: "nes", Genre: "Puzzle"})
	if len(got) != 1 || got[0] != "B (USA).nes" {
		t.Errorf("genre=Puzzle = %v, want B", got)
	}
	// Unknown genre matches nothing.
	if got := list(GameListOpts{SystemKey: "nes", Genre: "NoSuchGenre"}); len(got) != 0 {
		t.Errorf("genre=NoSuchGenre = %v, want none", got)
	}
	// Filters compose with the existing verify-state filter (verify
	// ingest never disturbs the scrape flags).
	got = list(GameListOpts{SystemKey: "nes", HasCover: &yes})
	if len(got) != 1 {
		t.Errorf("cover=yes after verify ingest = %v, want A still", got)
	}
}

// TestGenres pins the distinct-genre listing that feeds the library's
// genre filter select: sorted, non-empty, deduplicated.
func TestGenres(t *testing.T) {
	dir := t.TempDir()
	s, err := Open(filepath.Join(dir, "test.db"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer s.Close() //nolint:errcheck // test store

	if err := s.UpsertSystems([]SystemRow{{Key: "nes", Collection: "Nintendo", Bucket: "cartridge", SortOrder: 1}}); err != nil {
		t.Fatalf("systems: %v", err)
	}
	if err := s.ReplaceSystemGames("nes", []GameRow{
		{RelPath: "A.nes"}, {RelPath: "B.nes"}, {RelPath: "C.nes"}, {RelPath: "D.nes"},
	}, time.Now().UTC().Truncate(time.Second)); err != nil {
		t.Fatalf("games: %v", err)
	}
	if err := s.SetGameMeta("nes", []GameMeta{
		{RelPath: "A.nes", Genre: "Platform"},
		{RelPath: "B.nes", Genre: "Puzzle"},
		{RelPath: "C.nes", Genre: "Platform"}, // duplicate folds
	}); err != nil {
		t.Fatalf("meta: %v", err)
	}
	genres, err := s.Genres()
	if err != nil {
		t.Fatalf("Genres: %v", err)
	}
	if len(genres) != 2 || genres[0] != "Platform" || genres[1] != "Puzzle" {
		t.Errorf("genres = %v, want [Platform Puzzle]", genres)
	}
}
