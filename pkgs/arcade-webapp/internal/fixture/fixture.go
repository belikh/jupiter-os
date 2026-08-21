// Package fixture generates the self-authored arcade-webapp test corpus:
// three tiny Logiqx-format DATs (committed under testdata/dats/) describing
// dummy ROMs whose bytes come from a deterministic SHA-256 stream keyed by
// system + filename. Because we author both the DATs and the ROM bytes, the
// corpus is 100% legal to commit and regenerates byte-identically forever —
// `igir copy test report` over the regenerated tree must always show zero
// unmatched (plan §1.3 item 6, AC-3's fixture half; the shell gate lives at
// scripts/fixture-arcade.sh).
//
// Determinism rules (load-bearing — the committed DATs embed the hashes):
//   - no time, randomness, map-iteration order, or locale anywhere;
//   - ROM bytes are a pure function of (domain, key, size);
//   - game lists are ordered slices, never maps.
package fixture

import (
	"bytes"
	"crypto/md5"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"hash/crc32"
	"os"
	"path/filepath"
)

// domain namespaces the byte stream: bump to regenerate every ROM (and thus
// force re-committing the DATs).
const domain = "jupiter-os/arcade-fixture/v1"

// datVersion/datDate are fixed authoring metadata, deliberately NOT the run
// date — DAT output must be byte-stable across regenerations.
const (
	datVersion = "1.0"
	datDate    = "2026-08-21"
)

// Game is one dummy ROM: Name is the No-Intro-style base name (comma-free —
// the shell gate CSV-parses igir reports with a plain comma split), Size is
// the exact byte length of the generated ROM.
type Game struct {
	Name string
	Size int
}

// System is one fixture platform: a slug key, the DAT <name>, and the ROM
// filename extension (with dot).
type System struct {
	Key  string
	Name string
	Ext  string

	Games []Game
}

// Systems returns the fixture corpus: NES/SNES/GB, fake-realistic
// self-authored titles, sizes varied (some deliberately not multiples of
// the 32-byte hash block to exercise stream truncation).
func Systems() []System {
	return []System{
		{
			Key:  "nes",
			Name: "Nintendo Entertainment System (jupiter fixture)",
			Ext:  ".nes",
			Games: []Game{
				{Name: "Starlit Vault (USA)", Size: 24592},
				{Name: "Mecha Garden (Japan)", Size: 131072},
				{Name: "Pogo Postman (Europe)", Size: 65536},
				{Name: "Crystal Carp (USA) (Rev A)", Size: 40961},
				{Name: "Neon Ninjutsu (World)", Size: 32768},
			},
		},
		{
			Key:  "snes",
			Name: "Super Nintendo Entertainment System (jupiter fixture)",
			Ext:  ".sfc",
			Games: []Game{
				{Name: "Astral Almari (USA)", Size: 524288},
				{Name: "Bakery Bandits (Europe)", Size: 262144},
				{Name: "Turbo Tadpole (Japan)", Size: 131073},
				{Name: "Vault of Vertigo (USA) (Rev A)", Size: 786432},
			},
		},
		{
			Key:  "gb",
			Name: "Nintendo Game Boy (jupiter fixture)",
			Ext:  ".gb",
			Games: []Game{
				{Name: "Pocket Plumber (USA)", Size: 65536},
				{Name: "Grumble Weed (Japan)", Size: 32769},
				{Name: "Marble Marsupial (Europe)", Size: 131072},
				{Name: "Static Sheep (World)", Size: 8192},
			},
		},
	}
}

// RomFileName is the on-disk ROM name for a game: "<base name><ext>".
func RomFileName(s System, g Game) string {
	return g.Name + s.Ext
}

// RomKey is the byte-stream key for a ROM: "<system>/<filename>".
func RomKey(s System, g Game) string {
	return s.Key + "/" + RomFileName(s, g)
}

// RomBytes returns exactly size deterministic bytes for key: successive
// SHA-256 digests of domain|key|block-index, concatenated and truncated.
// A pure function — same key and size always yield the same bytes on every
// platform and Go version.
func RomBytes(key string, size int) []byte {
	if size < 0 {
		panic("fixture: negative size for " + key)
	}
	out := make([]byte, 0, size)
	var counter [8]byte
	for block := uint64(0); len(out) < size; block++ {
		binary.BigEndian.PutUint64(counter[:], block)
		h := sha256.New()
		h.Write([]byte(domain))
		h.Write([]byte{'|'})
		h.Write([]byte(key))
		h.Write([]byte{'|'})
		h.Write(counter[:])
		out = h.Sum(out)
	}
	return out[:size]
}

// Hashes returns the checksum triple Logiqx DATs carry for a byte slice.
type Hashes struct {
	Size int
	CRC  string // 8 hex chars, lowercase (clrmamepro/No-Intro convention)
	MD5  string
	SHA1 string
}

// Checksums computes the DAT checksums for b.
func Checksums(b []byte) Hashes {
	m5 := md5.Sum(b)  //nolint:gosec // DAT fixture format, not security
	s1 := sha1.Sum(b) //nolint:gosec // DAT fixture format, not security
	return Hashes{
		Size: len(b),
		CRC:  fmt.Sprintf("%08x", crc32.ChecksumIEEE(b)),
		MD5:  hex.EncodeToString(m5[:]),
		SHA1: hex.EncodeToString(s1[:]),
	}
}

// WriteROMs writes the whole fixture ROM tree under dir as
// <dir>/<system-key>/<rom filename>, mode 0o644 (dirs 0o755). Fails if any
// target exists with different content — regeneration is expected to be
// byte-identical, and a mismatch means the committed DATs are stale.
func WriteROMs(dir string) error {
	for _, s := range Systems() {
		sysDir := filepath.Join(dir, s.Key)
		if err := os.MkdirAll(sysDir, 0o755); err != nil {
			return err
		}
		for _, g := range s.Games {
			b := RomBytes(RomKey(s, g), g.Size)
			p := filepath.Join(sysDir, RomFileName(s, g))
			if existing, err := os.ReadFile(p); err == nil {
				if string(existing) == string(b) {
					continue
				}
				return fmt.Errorf("fixture: %s exists with different content — committed DATs are stale (bump domain?)", p)
			} else if !errors.Is(err, os.ErrNotExist) {
				return err
			}
			if err := os.WriteFile(p, b, 0o644); err != nil {
				return err
			}
		}
	}
	return nil
}

// DAT renders one system as a Logiqx datafile (the No-Intro XML format igir
// consumes), byte-stable across runs.
func DAT(s System) string {
	var b bytes.Buffer
	b.WriteString("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
	b.WriteString("<!DOCTYPE datafile PUBLIC \"-//Logiqx//DTD ROM Management Datafile//EN\" \"http://www.logiqx.com/Dats/datafile.dtd\">\n")
	b.WriteString("<datafile>\n")
	b.WriteString("\t<header>\n")
	fmt.Fprintf(&b, "\t\t<name>%s</name>\n", s.Name)
	b.WriteString("\t\t<description>Self-authored jupiter-os arcade-webapp fixture DAT: dummy ROM bytes, no copyrighted material</description>\n")
	fmt.Fprintf(&b, "\t\t<version>%s</version>\n", datVersion)
	fmt.Fprintf(&b, "\t\t<date>%s</date>\n", datDate)
	b.WriteString("\t\t<author>jupiter-os</author>\n")
	b.WriteString("\t\t<homepage>https://github.com/belikh/jupiter-os</homepage>\n")
	b.WriteString("\t</header>\n")
	for _, g := range s.Games {
		fmt.Fprintf(&b, "\t<game name=\"%s\">\n", g.Name)
		fmt.Fprintf(&b, "\t\t<description>%s</description>\n", g.Name)
		h := Checksums(RomBytes(RomKey(s, g), g.Size))
		fmt.Fprintf(&b, "\t\t<rom name=\"%s\" size=\"%d\" crc=\"%s\" md5=\"%s\" sha1=\"%s\"/>\n",
			RomFileName(s, g), h.Size, h.CRC, h.MD5, h.SHA1)
		b.WriteString("\t</game>\n")
	}
	b.WriteString("</datafile>\n")
	return b.String()
}

// WriteDATs writes one DAT per system under dir as <dir>/<key>.dat.
func WriteDATs(dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	for _, s := range Systems() {
		p := filepath.Join(dir, s.Key+".dat")
		if err := os.WriteFile(p, []byte(DAT(s)), 0o644); err != nil {
			return err
		}
	}
	return nil
}
