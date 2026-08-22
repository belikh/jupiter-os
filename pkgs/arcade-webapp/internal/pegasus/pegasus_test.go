package pegasus

import (
	"strings"
	"testing"
)

// The strict self-validation parser the generator runs on every
// candidate output before an atomic rename is allowed (gauntlet P6,
// AC-5). Fixtures here are exact bytes, not builder helpers — the
// format's quirks ARE the spec.

const validFixture = `collection: Nintendo Entertainment System
shortname: nes
launch: jupiter-retroarch -L fceumm "{file.path}"

game: Starlit Vault (USA)
file: Starlit Vault (USA).nes
description: A vault. In space.
release: 1987
developer: Fixture Dev
publisher: Fixture Pub
genre: Platform
rating: 3+
assets.boxFront: media/Starlit Vault (USA)/boxFront.png

game: Mecha Garden (Japan)
file: Mecha Garden (Japan).nes

# jupiter-pending-section (managed by arcade-webapp)
collection: Nintendo Entertainment System (Pending)
shortname: nes-pending
summary: Still downloading or incomplete - listed but not yet playable.

game: Zero Disc (USA)
file: Zero Disc (USA).chd
`

func TestParseValid(t *testing.T) {
	f, err := Parse(strings.NewReader(validFixture))
	if err != nil {
		t.Fatalf("Parse valid fixture: %v", err)
	}
	if got := len(f.Collections); got != 2 {
		t.Fatalf("collections = %d, want 2", got)
	}
	main := f.Collections[0]
	if main.Title != "Nintendo Entertainment System" || main.Shortname != "nes" {
		t.Fatalf("main header wrong: %+v", main)
	}
	wantLaunch := `jupiter-retroarch -L fceumm "{file.path}"`
	if main.Launch != wantLaunch {
		t.Fatalf("launch = %q, want %q", main.Launch, wantLaunch)
	}
	if len(main.Games) != 2 {
		t.Fatalf("main games = %d, want 2", len(main.Games))
	}
	g := main.Games[0]
	if g.Title != "Starlit Vault (USA)" || g.File != "Starlit Vault (USA).nes" {
		t.Fatalf("first game block wrong: %+v", g)
	}
	if g.Fields["description"] != "A vault. In space." || g.Fields["rating"] != "3+" {
		t.Fatalf("enrichment fields wrong: %+v", g.Fields)
	}
	if g.Assets["boxFront"] != "media/Starlit Vault (USA)/boxFront.png" {
		t.Fatalf("asset line wrong: %+v", g.Assets)
	}
	pend := f.Collections[1]
	if pend.Title != "Nintendo Entertainment System (Pending)" || pend.Shortname != "nes-pending" {
		t.Fatalf("pending header wrong: %+v", pend)
	}
	if pend.Launch != "" {
		t.Fatalf("pending collection must carry no launch, got %q", pend.Launch)
	}
	if len(pend.Games) != 1 || pend.Games[0].File != "Zero Disc (USA).chd" {
		t.Fatalf("pending games wrong: %+v", pend.Games)
	}
}

func TestValidateAcceptsValid(t *testing.T) {
	f, err := Parse(strings.NewReader(validFixture))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if err := f.Validate(); err != nil {
		t.Fatalf("Validate valid fixture: %v", err)
	}
}

func TestValidateRejectsDuplicateFileTargets(t *testing.T) {
	dup := `collection: A
shortname: a
launch: wrapper "{file.path}"

game: One
file: Same Game.nes

game: Two
file: Same Game.nes
`
	f, err := Parse(strings.NewReader(dup))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	err = f.Validate()
	if err == nil || !strings.Contains(err.Error(), "duplicate file") {
		t.Fatalf("want duplicate-file error, got %v", err)
	}
}

func TestValidateRejectsMissingMainLaunch(t *testing.T) {
	noLaunch := `collection: A
shortname: a

game: One
file: One.nes
`
	f, err := Parse(strings.NewReader(noLaunch))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	err = f.Validate()
	if err == nil || !strings.Contains(err.Error(), "launch") {
		t.Fatalf("want missing-launch error, got %v", err)
	}
}

func TestValidateRejectsGameWithoutFile(t *testing.T) {
	bad := `collection: A
shortname: a
launch: wrapper "{file.path}"

game: One
description: no file line at all
`
	f, err := Parse(strings.NewReader(bad))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	err = f.Validate()
	if err == nil || !strings.Contains(err.Error(), "no file") {
		t.Fatalf("want missing-file error, got %v", err)
	}
}

func TestParseRejectsMultilineValue(t *testing.T) {
	// An indented continuation means some value carried a raw newline —
	// Pegasus would end the entry there and reject the rest; our own
	// output must never contain one, so the parser refuses it outright.
	multi := "collection: A\nshortname: a\nlaunch: w \"{file.path}\"\n\ngame: One\n  continued prose\nfile: One.nes\n"
	if _, err := Parse(strings.NewReader(multi)); err == nil {
		t.Fatal("indented continuation accepted — newline-in-value leaked through")
	}
}

func TestParseRejectsGarbageLine(t *testing.T) {
	garbage := "collection: A\nthis line has no colon\n"
	if _, err := Parse(strings.NewReader(garbage)); err == nil {
		t.Fatal("colon-less line accepted")
	}
}

func TestParseRejectsMisplacedCollectionProperty(t *testing.T) {
	// shortname AFTER a game block can only be a broken header (the awk
	// state machine dropped exactly these lines from old pending
	// sections); our regenerated files never contain one.
	misplaced := `collection: A
shortname: a
launch: w "{file.path}"

game: One
file: One.nes
shortname: b
`
	if _, err := Parse(strings.NewReader(misplaced)); err == nil {
		t.Fatal("misplaced collection property accepted")
	}
}

func TestParseEmptyFileErrors(t *testing.T) {
	if _, err := Parse(strings.NewReader("")); err == nil {
		t.Fatal("empty file parsed into something")
	}
}
