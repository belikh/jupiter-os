package generate

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/pegasus"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// The P6 golden suite: a fixture store + served tree → exact output
// bytes. The generator writes the files kiosks read, so expectations are
// literal byte fixtures, never re-derivations of the code under test.

// newGenHarness builds a store with one cartridge system (nes) and one
// optical system (segacd, for .chd sniffing), plus their games trees.
func newGenHarness(t *testing.T) (*Generator, *store.Store, string) {
	t.Helper()
	root := t.TempDir()
	st, err := store.Open(filepath.Join(root, "arcade.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	if err := st.UpsertSystems([]store.SystemRow{
		{Key: "nes", Collection: "Nintendo Entertainment System", Bucket: "cartridge", Core: "fceumm", SortOrder: 1, Extensions: `["nes"]`},
		{Key: "wiiu", Collection: "Nintendo Wii U", Bucket: "modern", Emulator: "cemu", SortOrder: 2, Extensions: `["rpx"]`},
		{Key: "nolaunch", Collection: "No Launch Mapped", Bucket: "cartridge", SortOrder: 3, Extensions: `["nes"]`},
	}); err != nil {
		t.Fatal(err)
	}

	write := func(rel, body string) {
		t.Helper()
		p := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// nes: two complete ROMs, one hidden, media for one game.
	write("games/cartridge/nes/Astral Alpha (USA).nes", "aaaa")
	write("games/cartridge/nes/Beta Garden (Japan).nes", "bbbb")
	write("games/cartridge/nes/media/Beta Garden (Japan)/boxFront.png", "png!")
	// wiiu exercises the emulator launch mapping (modern bucket).
	write("games/modern/wiiu/Game.rpx", "rpx!")

	g := &Generator{
		St:            st,
		CartridgeRoot: filepath.Join(root, "games", "cartridge"),
		OpticalRoot:   filepath.Join(root, "games", "optical"),
		ModernRoot:    filepath.Join(root, "games", "modern"),
	}
	return g, st, root
}

// writeROM writes one fixture file (ROM bytes, media, etc.).
func writeROM(t *testing.T, path, body string) {
	t.Helper()
	writeROMBytes(t, path, []byte(body))
}

func writeROMBytes(t *testing.T, path string, body []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, body, 0o644); err != nil {
		t.Fatal(err)
	}
}

// seedNES inserts three visible games (one enriched, one with pending
// bytes later corrupted per-test) and one hidden row.
func seedNES(t *testing.T, st *store.Store) {
	t.Helper()
	if err := st.ReplaceSystemGames("nes", []store.GameRow{
		{RelPath: "Astral Alpha (USA).nes", SizeBytes: 4},
		{RelPath: "Beta Garden (Japan).nes", SizeBytes: 4},
	}, time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := st.ReplaceSystemGames("nes", []store.GameRow{
		{RelPath: "Hidden Gem (Europe).nes", SizeBytes: 9},
	}, time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := st.SetGameHidden("nes", "Hidden Gem (Europe).nes", true); err != nil {
		t.Fatalf("hide game: %v", err)
	}
	if err := st.SetGameMeta("nes", []store.GameMeta{
		{RelPath: "Astral Alpha (USA).nes",
			Description: "A vault in space.",
			Release:     "1987",
			Developer:   "Fixture Dev",
			Publisher:   "Fixture Pub",
			Genre:       "Platform",
			Rating:      "E"},
	}); err != nil {
		t.Fatal(err)
	}
}

const wantNesGolden = `collection: Nintendo Entertainment System
shortname: nes
launch: jupiter-retroarch -L fceumm "{file.path}"

game: Astral Alpha (USA)
file: Astral Alpha (USA).nes
description: A vault in space.
release: 1987
developer: Fixture Dev
publisher: Fixture Pub
genre: Platform
rating: E

game: Beta Garden (Japan)
file: Beta Garden (Japan).nes
assets.boxFront: media/Beta Garden (Japan)/boxFront.png
`

// TestGenerateGolden pins exact bytes: header order, launch line shape,
// enrichment field order, relative asset paths, hidden exclusion — and
// runs end-to-end through our own strict parser afterwards.
func TestGenerateGolden(t *testing.T) {
	g, st, root := newGenHarness(t)
	seedNES(t, st)

	res, err := g.Generate(false)
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	if !res.Validated {
		t.Fatal("run reports unvalidated output")
	}
	out, err := os.ReadFile(filepath.Join(root, "games", "cartridge", "nes", "metadata.pegasus.txt"))
	if err != nil {
		t.Fatalf("read generated file: %v", err)
	}
	if string(out) != wantNesGolden {
		t.Fatalf("golden mismatch:\n--- got ---\n%s\n--- want ---\n%s", out, wantNesGolden)
	}
	if strings.Contains(string(out), "Hidden Gem") {
		t.Fatal("hidden game leaked into generation")
	}

	// End-to-end: our own strict parser must accept exactly these bytes
	// (the same gate that guards every real write).
	f, err := pegasus.Parse(strings.NewReader(string(out)))
	if err != nil {
		t.Fatalf("self-parser rejected generated file: %v", err)
	}
	if len(f.Collections) != 1 || f.Collections[0].Launch == "" || len(f.Collections[0].Games) != 2 {
		t.Fatalf("parsed shape wrong: %+v", f.Collections)
	}
}

func TestGenerateEmulatorLaunchMapping(t *testing.T) {
	g, st, root := newGenHarness(t)
	if err := st.ReplaceSystemGames("wiiu", []store.GameRow{
		{RelPath: "Game.rpx", SizeBytes: 4},
	}, time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, err := g.Generate(false); err != nil {
		t.Fatalf("Generate: %v", err)
	}
	b, err := os.ReadFile(filepath.Join(root, "games", "modern", "wiiu", "metadata.pegasus.txt"))
	if err != nil {
		t.Fatal(err)
	}
	want := `collection: Nintendo Wii U
shortname: wiiu
launch: jupiter-cemu "{file.path}"

game: Game
file: Game.rpx
`
	if string(b) != want {
		t.Fatalf("emulator-launch golden mismatch:\n%s\nwant:\n%s", b, want)
	}
}

func TestGenerateByteStable(t *testing.T) {
	g, st, root := newGenHarness(t)
	seedNES(t, st)
	nesFile := filepath.Join(root, "games", "cartridge", "nes", "metadata.pegasus.txt")

	if _, err := g.Generate(false); err != nil {
		t.Fatal(err)
	}
	first, err := os.ReadFile(nesFile)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		if _, err := g.Generate(false); err != nil {
			t.Fatalf("run %d: %v", i, err)
		}
		again, err := os.ReadFile(nesFile)
		if err != nil {
			t.Fatal(err)
		}
		if string(again) != string(first) {
			t.Fatalf("run %d changed bytes:\n%s\nwas:\n%s", i, again, first)
		}
	}
}

// TestPendingSplit covers the completeness-sniff port: zeroed .chd goes
// to the trailing pending section (no launch), good magic stays main,
// other extensions are optimistic.
func TestPendingSplit(t *testing.T) {
	g, st, root := newGenHarness(t)
	dir := filepath.Join(root, "games", "cartridge", "nes")
	// Zeroed chd (aria2 preallocation shape), good chd, PK-good zip,
	// PK-bad zip, optimistic raw rom.
	writeROMBytes(t, filepath.Join(dir, "Zero Disc (USA).chd"), make([]byte, 64))
	writeROMBytes(t, filepath.Join(dir, "Good Disc (USA).chd"), append([]byte(mComprHDMagic), []byte("rest")...))
	writeROMBytes(t, filepath.Join(dir, "Good Zip (USA).zip"), append([]byte(zipPKMagic), []byte("rest")...))
	writeROMBytes(t, filepath.Join(dir, "Bad Zip (USA).zip"), []byte("not a zip at all"))
	writeROM(t, filepath.Join(dir, "Raw Optimist (USA).nes"), "raw")

	if err := st.ReplaceSystemGames("nes", []store.GameRow{
		{RelPath: "Bad Zip (USA).zip", SizeBytes: 15},
		{RelPath: "Good Disc (USA).chd", SizeBytes: 12},
		{RelPath: "Good Zip (USA).zip", SizeBytes: 12},
		{RelPath: "Raw Optimist (USA).nes", SizeBytes: 3},
		{RelPath: "Zero Disc (USA).chd", SizeBytes: 64},
	}, time.Now()); err != nil {
		t.Fatal(err)
	}

	if _, err := g.Generate(false); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(dir, "metadata.pegasus.txt"))
	if err != nil {
		t.Fatal(err)
	}
	out := string(b)

	// Main collection: only complete games.
	for _, main := range []string{"game: Good Disc (USA)", "game: Good Zip (USA)", "game: Raw Optimist (USA)"} {
		if !strings.Contains(out, main) {
			t.Errorf("main collection missing %q", main)
		}
	}
	mainPart := out[:strings.Index(out, PendingMarker)]
	if strings.Contains(mainPart, "Zero Disc") || strings.Contains(mainPart, "Bad Zip") {
		t.Error("incomplete games leaked into the main collection")
	}

	// Pending section: marker, own collection block without launch.
	if strings.Count(out, PendingMarker) != 1 {
		t.Errorf("pending marker count = %d, want 1", strings.Count(out, PendingMarker))
	}
	for _, want := range []string{
		"collection: Nintendo Entertainment System (Pending)",
		"shortname: nes-pending",
		"summary: Still downloading or incomplete - listed but not yet playable.",
		"game: Zero Disc (USA)",
		"file: Zero Disc (USA).chd",
		"game: Bad Zip (USA)",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("pending section missing %q", want)
		}
	}
	pendIdx := strings.Index(out, PendingMarker)
	if pend := out[pendIdx:]; strings.Contains(pend, "launch:") {
		t.Error("pending section carries a launch line — it must list, not launch")
	}

	// Idempotent rebuild: regenerating over the existing file reproduces
	// identical bytes (stale sections cannot accumulate).
	before, _ := os.ReadFile(filepath.Join(dir, "metadata.pegasus.txt"))
	if _, err := g.Generate(false); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(filepath.Join(dir, "metadata.pegasus.txt"))
	if string(before) != string(after) {
		t.Fatalf("regeneration not idempotent:\n--before--\n%s\n--after--\n%s", before, after)
	}
}

func TestCompletenessSniffUnits(t *testing.T) {
	dir := t.TempDir()
	mk := func(name string, head []byte) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, head, 0o644); err != nil {
			t.Fatal(err)
		}
		return p
	}
	cases := []struct {
		name string
		path string
		want bool
	}{
		{"mcomprhd v2 ok", mk("a.chd", []byte("\x4d\x43\x6f\x6d\x70\x72\x48\x44 tail")), true},
		{"comprhd v1 prefix ok", mk("b.chd", []byte("\x43\x6f\x6d\x70\x72\x48\x44 v1")), true},
		{"zeroed chd bad", mk("c.chd", make([]byte, 8)), false},
		{"short chd bad", mk("d.chd", []byte{0x4d}), false},
		{"zip PK ok", mk("e.zip", []byte("PK\x03\x04")), true},
		{"zip non-PK bad", mk("f.zip", []byte("NOPE!!!!")), false},
		{"uppercase CHD ok", mk("g.CHD", []byte(mComprHDMagic)), true},
		{"raw ext optimistic", mk("h.nes", nil), true},
		{"iso optimistic", mk("i.iso", make([]byte, 8)), true},
		{"unreadable", filepath.Join(dir, "missing.chd"), false},
	}
	for _, tc := range cases {
		if got := romComplete(tc.path); got != tc.want {
			t.Errorf("%s: romComplete = %v, want %v", tc.name, got, tc.want)
		}
	}
}

// TestAtomicRenameKeepsOldFileOnAbortedGeneration is the kill-safety
// simulation (AC-5): a generation that aborts mid-flight — here because
// the system lost its launch mapping between runs, exactly what happens
// when a catalogue row loses its core — must leave the previously served
// file byte-intact and clean up its temp sibling.
func TestAtomicRenameKeepsOldFileOnAbortedGeneration(t *testing.T) {
	g, st, root := newGenHarness(t)
	nlDir := filepath.Join(root, "games", "cartridge", "nolaunch")
	writeROM(t, filepath.Join(nlDir, "X.nes"), "x")
	if err := st.UpsertSystems([]store.SystemRow{
		{Key: "nolaunch", Collection: "No Launch Mapped", Bucket: "cartridge", Core: "fakecore", SortOrder: 3, Extensions: `["nes"]`},
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.ReplaceSystemGames("nolaunch", []store.GameRow{{RelPath: "X.nes", SizeBytes: 1}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	res, err := g.Generate(false)
	if err != nil {
		t.Fatalf("first generate: %v", err)
	}
	assertOutcome(t, res, "nolaunch", OutcomeGenerated)

	nlFile := filepath.Join(nlDir, "metadata.pegasus.txt")
	good, err := os.ReadFile(nlFile)
	if err != nil {
		t.Fatal(err)
	}

	// The catalogue row loses its core (the abort trigger).
	if err := st.UpsertSystems([]store.SystemRow{
		{Key: "nolaunch", Collection: "No Launch Mapped", Bucket: "cartridge", SortOrder: 3, Extensions: `["nes"]`},
	}); err != nil {
		t.Fatal(err)
	}
	res, err = g.Generate(false)
	if err != nil {
		t.Fatalf("per-system failure must not abort the batch: %v", err)
	}
	assertOutcome(t, res, "nolaunch", OutcomeFailed)

	after, err := os.ReadFile(nlFile)
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != string(good) {
		t.Fatalf("old file clobbered by aborted generation:\n%s\nwas:\n%s", after, good)
	}
	// No temp siblings left behind.
	entries, _ := os.ReadDir(nlDir)
	for _, e := range entries {
		if strings.Contains(e.Name(), ".tmp") {
			t.Errorf("temp sibling left behind: %s", e.Name())
		}
	}

	// Validation-failure variant through our own parser: a value that
	// smuggled a raw newline manifests as an INDENTED continuation line —
	// the exact shape the strict gate refuses — while the real target
	// still holds the good bytes.
	corrupt := strings.Replace(string(good), "file: X.nes", "file: X.nes\n  description: smuggled newline", 1)
	if _, err := pegasus.Parse(strings.NewReader(corrupt)); err == nil {
		t.Fatal("parser accepted a smuggled newline — kill-safety gate is decorative")
	}
}

// TestDryRunWritesNothing pins Generate(true): validated, recorded, but
// the served trees stay untouched (P7's diff-preview hook).
func TestDryRunWritesNothing(t *testing.T) {
	g, st, root := newGenHarness(t)
	seedNES(t, st)
	res, err := g.GenerateOptions(true, Options{})
	if err != nil {
		t.Fatalf("dry run: %v", err)
	}
	if res.Systems[0].Outcome != OutcomeGenerated {
		t.Fatalf("dry-run outcome = %q, want %q", res.Systems[0].Outcome, OutcomeGenerated)
	}
	nesFile := filepath.Join(root, "games", "cartridge", "nes", "metadata.pegasus.txt")
	if _, err := os.Stat(nesFile); !os.IsNotExist(err) {
		t.Fatal("dry run wrote the target file")
	}
}

// TestRelativePathsOnly asserts the kiosk contract: every file:/assets
// value is relative (kiosks mount the tree elsewhere).
func TestRelativePathsOnly(t *testing.T) {
	g, st, root := newGenHarness(t)
	seedNES(t, st)
	if _, err := g.Generate(false); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(root, "games", "cartridge", "nes", "metadata.pegasus.txt"))
	if err != nil {
		t.Fatal(err)
	}
	for lineNo, line := range strings.Split(string(b), "\n") {
		for _, key := range []string{"file: ", "assets."} {
			if strings.HasPrefix(line, key) {
				v := line[strings.Index(line, ":")+1:]
				v = strings.TrimSpace(v)
				if strings.HasPrefix(v, "/") || strings.HasPrefix(v, "..") {
					t.Errorf("line %d carries non-relative path: %q", lineNo+1, line)
				}
			}
		}
	}
}

// TestSkipsEmptyAndUnlaunchable: systems with no visible games are
// skipped (no file churn); a system with games but no launch mapping
// fails loudly instead of writing an unlaunchable collection.
func TestSkipsEmptyAndUnlaunchable(t *testing.T) {
	g, st, root := newGenHarness(t)
	res, err := g.Generate(false)
	if err != nil {
		t.Fatalf("Generate with no games at all: %v", err)
	}
	if n := len(res.Systems); n != 0 {
		t.Fatalf("outcomes = %d, want 0 (nothing populated)", n)
	}

	// nolaunch has games but neither core nor emulator mapped.
	nlDir := filepath.Join(root, "games", "cartridge", "nolaunch")
	writeROM(t, filepath.Join(nlDir, "X.nes"), "x")
	if err := st.ReplaceSystemGames("nolaunch", []store.GameRow{{RelPath: "X.nes", SizeBytes: 1}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	res, err = g.Generate(false)
	if err != nil {
		t.Fatalf("per-system failure must not abort the batch: %v", err)
	}
	var found bool
	for _, oc := range res.Systems {
		if oc.Sys == "nolaunch" {
			found = true
			if oc.Outcome != OutcomeFailed || !strings.Contains(oc.Err, "launch") {
				t.Fatalf("nolaunch outcome = %+v, want failed with launch error", oc)
			}
		}
	}
	if !found {
		t.Fatal("nolaunch outcome missing from run detail")
	}
	if _, err := os.Stat(filepath.Join(nlDir, "metadata.pegasus.txt")); !os.IsNotExist(err) {
		t.Fatal("unlaunchable system still got a metadata file written")
	}
}

func TestNewlinesInValuesSanitized(t *testing.T) {
	g, st, root := newGenHarness(t)
	seedNES(t, st)
	if err := st.SetGameMeta("nes", []store.GameMeta{
		{RelPath: "Beta Garden (Japan).nes", Description: "line one\nline two\r\nline three"},
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := g.Generate(false); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(root, "games", "cartridge", "nes", "metadata.pegasus.txt"))
	if strings.Contains(string(b), "\nline two") && false {
		t.Fatal("unreachable")
	}
	// The description must sit on ONE line; the strict parser enforces it.
	f, err := pegasus.Parse(strings.NewReader(string(b)))
	if err != nil {
		t.Fatalf("newline survived sanitization: %v", err)
	}
	desc := f.Collections[0].Games[1].Fields["description"]
	if strings.Contains(desc, "\n") || desc != "line one; line two; line three" {
		t.Fatalf("sanitized description = %q", desc)
	}
}

func assertOutcome(t *testing.T, r Result, sys, outcome string) {
	t.Helper()
	for _, oc := range r.Systems {
		if oc.Sys == sys {
			if oc.Outcome != outcome {
				t.Fatalf("%s outcome = %q, want %q (err=%q)", sys, oc.Outcome, outcome, oc.Err)
			}
			return
		}
	}
	t.Fatalf("%s missing from run outcomes %+v", sys, r.Systems)
}

// TestMissingDirFailsLoudly: DB rows without a served tree dir (unmounted
// bucket) fail that system with a named error — never a silent skip, and
// nothing gets created on disk.
func TestMissingDirFailsLoudly(t *testing.T) {
	g, st, _ := newGenHarness(t)
	if err := st.ReplaceSystemGames("wiiu", []store.GameRow{
		{RelPath: "Ghost.rpx", SizeBytes: 4},
	}, time.Now()); err != nil {
		t.Fatal(err)
	}
	os.RemoveAll(filepath.Join(g.ModernRoot, "wiiu"))
	res, err := g.Generate(false)
	if err != nil {
		t.Fatalf("batch must survive one bad system: %v", err)
	}
	assertOutcome(t, res, "wiiu", OutcomeFailed)
	for _, oc := range res.Systems {
		if oc.Sys == "wiiu" && !strings.Contains(oc.Err, "dir missing") {
			t.Fatalf("wiiu err = %q, want the dir-missing reason", oc.Err)
		}
	}
}
