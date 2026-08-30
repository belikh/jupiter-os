package fixture

import (
	"bytes"
	"crypto/sha256"
	"encoding/xml"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
)

// committedDats is where the repo keeps the canonical fixture DATs (written
// once by `go run ./cmd/fixturegen --dats testdata/dats`, then committed).
// The tests below pin the generator to those committed bytes forever: any
// change to game lists or the byte stream must be a deliberate re-bootstrap.
const committedDats = "../../testdata/dats"

// logiqx mirrors the subset of the Logiqx datafile format the corpus uses.
type logiqx struct {
	XMLName xml.Name `xml:"datafile"`
	Header  struct {
		Name        string `xml:"name"`
		Description string `xml:"description"`
		Version     string `xml:"version"`
	} `xml:"header"`
	Games []struct {
		Name string `xml:"name,attr"`
		Roms []struct {
			Name string `xml:"name,attr"`
			Size int    `xml:"size,attr"`
			CRC  string `xml:"crc,attr"`
			MD5  string `xml:"md5,attr"`
			SHA1 string `xml:"sha1,attr"`
		} `xml:"rom"`
	} `xml:"game"`
}

func parseDat(t *testing.T, path string) logiqx {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var d logiqx
	if err := xml.Unmarshal(raw, &d); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
	return d
}

// TestRomsMatchCommittedDATs is the offline half of the zero-unmatched gate
// (plan §1.3 item 6): every committed DAT rom entry must be byte-exactly
// reproducible by the generator (size + CRC32 + MD5 + SHA1), in both
// directions — no DAT entry without generator output, no generated ROM
// without a DAT entry. `make fixture-arcade` runs the same equivalence
// through real igir; this test catches drift without needing igir.
func TestRomsMatchCommittedDATs(t *testing.T) {
	for _, s := range Systems() {
		s := s
		t.Run(s.Key, func(t *testing.T) {
			d := parseDat(t, filepath.Join(committedDats, s.Key+".dat"))

			if d.Header.Name != s.Name {
				t.Errorf("DAT header name = %q, want %q", d.Header.Name, s.Name)
			}
			if len(d.Games) != len(s.Games) {
				t.Fatalf("DAT has %d games, generator has %d", len(d.Games), len(s.Games))
			}

			datByRomName := make(map[string]*struct {
				Name string `xml:"name,attr"`
				Roms []struct {
					Name string `xml:"name,attr"`
					Size int    `xml:"size,attr"`
					CRC  string `xml:"crc,attr"`
					MD5  string `xml:"md5,attr"`
					SHA1 string `xml:"sha1,attr"`
				} `xml:"rom"`
			}, len(d.Games))
			for i := range d.Games {
				datByRomName[d.Games[i].Roms[0].Name] = &d.Games[i]
			}

			for _, g := range s.Games {
				rom := RomFileName(s, g)
				dg, ok := datByRomName[rom]
				if !ok {
					t.Errorf("generated ROM %q has no DAT entry — DATs are stale, re-bootstrap testdata/dats", rom)
					continue
				}
				r := dg.Roms[0]
				b := RomBytes(RomKey(s, g), g.Size)
				h := Checksums(b)
				if r.Size != h.Size {
					t.Errorf("%s: DAT size = %d, generated = %d", rom, r.Size, h.Size)
				}
				if r.CRC != h.CRC {
					t.Errorf("%s: DAT crc = %s, generated = %s", rom, r.CRC, h.CRC)
				}
				if r.MD5 != h.MD5 {
					t.Errorf("%s: DAT md5 = %s, generated = %s", rom, r.MD5, h.MD5)
				}
				if r.SHA1 != h.SHA1 {
					t.Errorf("%s: DAT sha1 = %s, generated = %s", rom, r.SHA1, h.SHA1)
				}
				if dg.Name != g.Name {
					t.Errorf("%s: DAT game name = %q, want %q", rom, dg.Name, g.Name)
				}
			}
		})
	}
}

// TestWriteDATsMatchesCommittedCorpus pins the generator↔committed
// equivalence for the WHOLE corpus directory: WriteDATs' output must be
// byte-identical to testdata/dats (DATs AND, since remediation W4b, the
// dat-lock.json pinning them). A domain bump or game-list change that
// regenerates the DATs without re-committing — or a hand-edited lock —
// fails here and in dats' own TestCommittedCorpusLockMatchesBytes.
func TestWriteDATsMatchesCommittedCorpus(t *testing.T) {
	dir := t.TempDir()
	if err := WriteDATs(dir); err != nil {
		t.Fatalf("WriteDATs: %v", err)
	}
	for _, s := range Systems() {
		want, err := os.ReadFile(filepath.Join(committedDats, s.Key+".dat"))
		if err != nil {
			t.Fatalf("read committed %s.dat: %v", s.Key, err)
		}
		got, err := os.ReadFile(filepath.Join(dir, s.Key+".dat"))
		if err != nil {
			t.Fatalf("read generated %s.dat: %v", s.Key, err)
		}
		if !bytes.Equal(got, want) {
			t.Errorf("%s.dat: generator output differs from the committed corpus — re-bootstrap testdata/dats", s.Key)
		}
	}
	wantLock, err := os.ReadFile(filepath.Join(committedDats, "dat-lock.json"))
	if err != nil {
		t.Fatalf("read committed dat-lock.json: %v (the W4b corpus lock is missing)", err)
	}
	gotLock, err := os.ReadFile(filepath.Join(dir, "dat-lock.json"))
	if err != nil {
		t.Fatalf("WriteDATs wrote no dat-lock.json: %v", err)
	}
	if !bytes.Equal(gotLock, wantLock) {
		t.Errorf("generated dat-lock.json differs from the committed lock:\ncommitted:\n%s\ngenerated:\n%s", wantLock, gotLock)
	}
}

// TestWriteROMsDeterministic pins the byte stream: two WriteROMs runs must
// produce identical trees (same files, same bytes). The committed DATs embed
// these hashes, so any wobble here is a stale-DAT bug.
func TestWriteROMsDeterministic(t *testing.T) {
	snapshot := func(dir string) map[string][32]byte {
		t.Helper()
		out := make(map[string][32]byte)
		err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() {
				return nil
			}
			rel, err := filepath.Rel(dir, path)
			if err != nil {
				return err
			}
			raw, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			sum := sha256.Sum256(raw)
			out[rel] = sum
			return nil
		})
		if err != nil {
			t.Fatalf("walk %s: %v", dir, err)
		}
		return out
	}

	a, b := t.TempDir(), t.TempDir()
	if err := WriteROMs(a); err != nil {
		t.Fatalf("WriteROMs(a): %v", err)
	}
	if err := WriteROMs(b); err != nil {
		t.Fatalf("WriteROMs(b): %v", err)
	}

	sa, sb := snapshot(a), snapshot(b)
	if len(sa) == 0 {
		t.Fatal("WriteROMs produced no files")
	}
	if len(sa) != len(sb) {
		t.Fatalf("tree sizes differ: %d vs %d files", len(sa), len(sb))
	}
	for rel, ha := range sa {
		hb, ok := sb[rel]
		if !ok {
			t.Errorf("file %s missing from second run", rel)
			continue
		}
		if ha != hb {
			t.Errorf("file %s differs between runs: %x vs %x", rel, ha, hb)
		}
	}
}

// TestWriteROMsIdempotentAndStaleDetection checks the guard rails: a clean
// re-run is accepted, but a file whose content no longer matches the
// generator is reported as stale (so nobody silently forks the corpus).
func TestWriteROMsIdempotentAndStaleDetection(t *testing.T) {
	dir := t.TempDir()
	if err := WriteROMs(dir); err != nil {
		t.Fatalf("first WriteROMs: %v", err)
	}
	if err := WriteROMs(dir); err != nil {
		t.Fatalf("idempotent re-run: %v", err)
	}

	s := Systems()[0]
	g := s.Games[0]
	p := filepath.Join(dir, s.Key, RomFileName(s, g))
	if err := os.WriteFile(p, bytes.Repeat([]byte{0}, g.Size), 0o644); err != nil {
		t.Fatalf("corrupt fixture file: %v", err)
	}
	if err := WriteROMs(dir); err == nil {
		t.Fatal("WriteROMs accepted a corrupted (stale-DAT) file; want error")
	}
}

// TestNamesWellFormed enforces the invariants the rest of the corpus relies
// on: comma-free names (the igir report CSV is comma-split by the shell
// gate), uniqueness per system, and the ROM filename extension.
func TestNamesWellFormed(t *testing.T) {
	for _, s := range Systems() {
		seen := make(map[string]bool, len(s.Games))
		for _, g := range s.Games {
			if g.Name == "" {
				t.Errorf("%s: empty game name", s.Key)
			}
			for _, r := range g.Name {
				if r == ',' {
					t.Errorf("%s: game name %q contains a comma (breaks CSV field parsing in the gate)", s.Key, g.Name)
				}
			}
			if seen[g.Name] {
				t.Errorf("%s: duplicate game name %q", s.Key, g.Name)
			}
			seen[g.Name] = true
			if fn := RomFileName(s, g); filepath.Ext(fn) != s.Ext {
				t.Errorf("%s: ROM filename %q lacks extension %q", s.Key, fn, s.Ext)
			}
			if g.Size <= 0 {
				t.Errorf("%s: game %q has non-positive size %d", s.Key, g.Name, g.Size)
			}
		}
	}
}

// TestDATByteStable pins the renderer: same system in, same bytes out.
func TestDATByteStable(t *testing.T) {
	for _, s := range Systems() {
		if DAT(s) != DAT(s) {
			t.Errorf("%s: DAT() not byte-stable", s.Key)
		}
	}
}
