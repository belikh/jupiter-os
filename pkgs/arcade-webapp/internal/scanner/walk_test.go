package scanner

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/catalogue"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

func writeFile(t *testing.T, path string, size int) {
	t.Helper()
	b := make([]byte, size)
	for i := range b {
		b[i] = byte(i % 251) // deterministic, non-zero
	}
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatal(err)
	}
}

func mustDir(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
}

func rowsByPath(rows []store.GameRow) map[string]int64 {
	m := map[string]int64{}
	for _, r := range rows {
		m[r.RelPath] = r.SizeBytes
	}
	return m
}

// ADV-P1-01: cartridge systems hold No-Intro .zip archives (igir COPY has
// no extract; cartridge-scrape.sh adds zip to its regex for exactly this
// reason). A zip in a per-system dir is a game.
func TestScanSystemDirCountsZips(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "Alpha Zone (USA).zip"), 1024)
	writeFile(t, filepath.Join(dir, "Beta Boulevard (Europe).zip"), 2048)
	writeFile(t, filepath.Join(dir, "Gamma Grove (Japan).zip"), 512)
	writeFile(t, filepath.Join(dir, "Loose Cart (USA).nes"), 256)
	writeFile(t, filepath.Join(dir, "notes.txt"), 40) // not a game, no game in dir? there IS — absorbed

	sys := catalogue.System{Key: "nes", Extensions: []string{"nes"}}
	rows, err := scanSystemDir(dir, sys)
	if err != nil {
		t.Fatalf("scanSystemDir: %v", err)
	}
	m := rowsByPath(rows)
	if len(m) != 4 {
		t.Fatalf("games = %d (%v), want 4 (3 zips + 1 loose .nes)", len(m), m)
	}
	// notes.txt is a companion absorbed by the single... no: 4 games share
	// the dir, and "notes" prefixes no game → unattributed.
	if got := m["Loose Cart (USA).nes"]; got != 256 {
		t.Errorf("loose .nes size = %d, want 256", got)
	}
	if got := m["Alpha Zone (USA).zip"]; got != 1024 {
		t.Errorf("zip size = %d, want 1024", got)
	}
}

// ADV-P1-01: cue/bin optical systems — the .cue is the game, .bin tracks
// are companions whose bytes must land in the game's size (a "1 rom / 4 B"
// card for a multi-GB rip is the bug this guards).
func TestScanSystemDirCueBinCompanions(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "Turbo Disc (USA).cue"), 128)
	writeFile(t, filepath.Join(dir, "Turbo Disc (USA) (Track 1).bin"), 4096)
	writeFile(t, filepath.Join(dir, "Turbo Disc (USA) (Track 2).bin"), 2048)
	writeFile(t, filepath.Join(dir, "Rival Platter (Europe).cue"), 96)
	writeFile(t, filepath.Join(dir, "Rival Platter (Europe) (Track 1).bin"), 8192)

	sys := catalogue.System{Key: "segacd", Extensions: []string{"iso", "cue", "chd"}}
	rows, err := scanSystemDir(dir, sys)
	if err != nil {
		t.Fatalf("scanSystemDir: %v", err)
	}
	m := rowsByPath(rows)
	if len(m) != 2 {
		t.Fatalf("games = %d (%v), want 2 (the .cues)", len(m), m)
	}
	if got := m["Turbo Disc (USA).cue"]; got != 128+4096+2048 {
		t.Errorf("Turbo Disc size = %d, want %d (cue + track bytes)", got, 128+4096+2048)
	}
	if got := m["Rival Platter (Europe).cue"]; got != 96+8192 {
		t.Errorf("Rival Platter size = %d, want %d", got, 96+8192)
	}
}

// ADV-P1-01: multi-file game directories — one game file plus its
// companions in a per-game dir (the Wii U Loadiine / redump dir-per-game
// shape).
func TestScanSystemDirMultiFileGameDir(t *testing.T) {
	root := t.TempDir()
	gameDir := filepath.Join(root, "Mega Saga (USA)")
	mustDir(t, gameDir)
	writeFile(t, filepath.Join(gameDir, "Mega Saga (USA).cue"), 64)
	writeFile(t, filepath.Join(gameDir, "Mega Saga (USA) (Track 1).bin"), 1024)
	writeFile(t, filepath.Join(gameDir, "Mega Saga (USA) (Track 2).bin"), 512)

	sys := catalogue.System{Key: "segacd", Extensions: []string{"iso", "cue", "chd"}}
	rows, err := scanSystemDir(root, sys)
	if err != nil {
		t.Fatalf("scanSystemDir: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("games = %d (%v), want 1", len(rows), rows)
	}
	if got := rows[0].RelPath; got != filepath.Join("Mega Saga (USA)", "Mega Saga (USA).cue") {
		t.Errorf("game rel path = %q", got)
	}
	if rows[0].SizeBytes != 64+1024+512 {
		t.Errorf("game size = %d, want %d", rows[0].SizeBytes, 64+1024+512)
	}
}

// ADV-P1-01: bare .bin files with no cue/game alongside are NOT games (bin
// is in no optical system's extension list; it only travels as a
// companion).
func TestScanSystemDirBareBinsAreNotGames(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "Orphan (USA) (Track 1).bin"), 4096)
	writeFile(t, filepath.Join(dir, "Orphan (USA) (Track 2).bin"), 2048)

	sys := catalogue.System{Key: "segacd", Extensions: []string{"iso", "cue", "chd"}}
	rows, err := scanSystemDir(dir, sys)
	if err != nil {
		t.Fatalf("scanSystemDir: %v", err)
	}
	if len(rows) != 0 {
		t.Fatalf("games = %d (%v), want 0 (no cue, bins are companions)", len(rows), rows)
	}
}

// bin IS a listed extension for some cartridge systems (a2600: bin,a26) —
// there a bare .bin is a game, not a companion.
func TestScanSystemDirBinIsGameWhenListed(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "Combat Zone (USA).bin"), 2048)

	sys := catalogue.System{Key: "a2600", Extensions: []string{"bin", "a26"}}
	rows, err := scanSystemDir(dir, sys)
	if err != nil {
		t.Fatalf("scanSystemDir: %v", err)
	}
	if len(rows) != 1 || rows[0].SizeBytes != 2048 {
		t.Fatalf("rows = %v, want one 2048-byte game", rows)
	}
}

// Dotfiles never count — not as games, not as companions whose size lands
// in a game (cartridge-scrape.sh's .gitkeep lesson).
func TestScanSystemDirSkipsDotfiles(t *testing.T) {
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, ".gitkeep"), 1)
	writeFile(t, filepath.Join(dir, ".hidden.nes"), 128)
	writeFile(t, filepath.Join(dir, "Real (USA).nes"), 256)

	sys := catalogue.System{Key: "nes", Extensions: []string{"nes"}}
	rows, err := scanSystemDir(dir, sys)
	if err != nil {
		t.Fatalf("scanSystemDir: %v", err)
	}
	m := rowsByPath(rows)
	if len(m) != 1 {
		t.Fatalf("games = %d (%v), want 1", len(m), m)
	}
	if m["Real (USA).nes"] != 256 {
		t.Errorf("Real (USA).nes size = %d, want 256 (must not absorb .gitkeep)", m["Real (USA).nes"])
	}
}

// Missing system dir = clean empty result (the caller treats it as
// "system not populated", not an error).
func TestScanSystemDirMissingDirIsEmpty(t *testing.T) {
	sys := catalogue.System{Key: "nes", Extensions: []string{"nes"}}
	rows, err := scanSystemDir(filepath.Join(t.TempDir(), "nes"), sys)
	if err != nil {
		t.Fatalf("scanSystemDir on missing dir: %v, want nil error", err)
	}
	if len(rows) != 0 {
		t.Fatalf("rows = %v, want empty", rows)
	}
}
