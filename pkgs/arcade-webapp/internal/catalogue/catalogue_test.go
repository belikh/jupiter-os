package catalogue

import (
	"os"
	"path/filepath"
	"testing"
)

func writeTSV(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "cartridge-catalogue.tsv")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestParseMatchesNixSemantics(t *testing.T) {
	// Same shape as scripts/cartridge-catalogue.tsv: '#' comments, blank
	// lines, 8 tab-separated columns, "-" meaning null.
	p := writeTSV(t, `# header comment
# another comment

nes	Nintendo Entertainment System	fceumm	-	nes	-	cartridge	Minerva - NES.torrent
ps1	Sony PlayStation	beetle-psx	-	chd,cue,iso,m3u	psx	optical	Minerva - PS1.torrent
wiiu	Nintendo Wii U	-	cemu	wua,rpx	-	modern	-
pokemonmini	Nintendo Pokemon Mini	pokemini	-	min	pokemini	cartridge	-
`)

	systems, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(systems) != 4 {
		t.Fatalf("len(systems) = %d, want 4", len(systems))
	}

	nes := systems[0]
	if nes.Key != "nes" || nes.Collection != "Nintendo Entertainment System" {
		t.Errorf("systems[0] = %+v, want nes/NES", nes)
	}
	if nes.Core != "fceumm" || nes.Emulator != "" {
		t.Errorf("nes core/emulator = %q/%q, want fceumm/empty", nes.Core, nes.Emulator)
	}
	if len(nes.Extensions) != 1 || nes.Extensions[0] != "nes" {
		t.Errorf("nes extensions = %v, want [nes]", nes.Extensions)
	}
	if nes.SkyHandle != "" || nes.Bucket != "cartridge" || nes.Torrent != "Minerva - NES.torrent" {
		t.Errorf("nes sky/bucket/torrent = %q/%q/%q", nes.SkyHandle, nes.Bucket, nes.Torrent)
	}

	ps1 := systems[1]
	if ps1.SkyHandle != "psx" || ps1.Bucket != "optical" {
		t.Errorf("ps1 sky/bucket = %q/%q, want psx/optical", ps1.SkyHandle, ps1.Bucket)
	}
	if len(ps1.Extensions) != 4 {
		t.Errorf("ps1 extensions = %v, want 4", ps1.Extensions)
	}

	wiiu := systems[2]
	if wiiu.Core != "" || wiiu.Emulator != "cemu" || wiiu.Bucket != "modern" {
		t.Errorf("wiiu = %+v, want coreless cemu modern", wiiu)
	}

	pm := systems[3]
	if pm.SkyHandle != "pokemini" || pm.Torrent != "" {
		t.Errorf("pokemonmini sky/torrent = %q/%q, want pokemini/empty", pm.SkyHandle, pm.Torrent)
	}
}

func TestParseRealCommittedTSV(t *testing.T) {
	// The committed fleet catalogue is the contract; every row must parse
	// with the same semantics modules/services/arcade-catalogue.nix applies.
	// The TSV lives at the repo root, outside this package's tree, so the
	// nix buildGoModule sandbox (src = pkgs/arcade-webapp only) can't see it
	// — skip there; the repo-root `go test ./...` and the VM test (which
	// scans a store copy of the real TSV) both exercise it.
	const nixRowCount = 61 // rows in scripts/cartridge-catalogue.tsv as of 2026-08-21
	p := filepath.Join("..", "..", "..", "..", "scripts", "cartridge-catalogue.tsv")
	if _, err := os.Stat(p); err != nil {
		t.Skipf("repo TSV not reachable from this sandbox: %v", err)
	}
	systems, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(systems) < 60 {
		t.Errorf("len(systems) = %d, want >= 60 (committed catalogue grew? update this test)", len(systems))
	}
	if len(systems) != nixRowCount {
		t.Errorf("len(systems) = %d, want %d (a TSV row was added/removed — update nixRowCount)", len(systems), nixRowCount)
	}
	seen := map[string]bool{}
	for _, s := range systems {
		if seen[s.Key] {
			t.Errorf("duplicate system key %q", s.Key)
		}
		seen[s.Key] = true
		if s.Bucket != "cartridge" && s.Bucket != "optical" && s.Bucket != "modern" {
			t.Errorf("system %q bucket = %q", s.Key, s.Bucket)
		}
		if s.Collection == "" || len(s.Extensions) == 0 {
			t.Errorf("system %q missing collection/extensions", s.Key)
		}
	}
}

func TestParseRejectsMalformedRow(t *testing.T) {
	p := writeTSV(t, "nes\tonly\tthree\tcolumns\n")
	if _, err := Load(p); err == nil {
		t.Fatal("Load succeeded on a 4-column row, want error")
	}
}

func TestParseMissingFileIsError(t *testing.T) {
	if _, err := Load(filepath.Join(t.TempDir(), "nope.tsv")); err == nil {
		t.Fatal("Load succeeded on missing file, want error")
	}
}

func TestHasROMExtension(t *testing.T) {
	s := System{Key: "nes", Extensions: []string{"nes"}}
	cases := map[string]bool{
		"Game (USA).nes": true,
		"Game (USA).NES": true, // case-insensitive like the inventory pattern (-iregex)
		"Game (USA).zip": false,
		"Game.nes.bak":   false,
		".hidden.nes":    true, // extension match only; dotfile skip is the walker's policy
	}
	for name, want := range cases {
		if got := s.HasROMExtension(name); got != want {
			t.Errorf("HasROMExtension(%q) = %v, want %v", name, got, want)
		}
	}
}
