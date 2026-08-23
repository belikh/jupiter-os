// Package inventory builds the fleet arcade-inventory document the
// legacy jupiter-arcade-inventory unit wrote to
// /tank/archive/retro/state/inventory.json and scripts/arcade-status.sh
// (make status-arcade) consumed over SSH (gauntlet plan §2 P8, goal 7
// wrap-up): the webapp now SERVES the same document at
// /inventory.json with FIELD-FOR-FIELD PARITY, so operators keep their
// consumer during the europa transition.
//
// Parity contract (pinned by TestLegacyShapeParity against a fixture
// emitted in the old jq shape):
//
//	{
//	  "generated_at": "2026-08-23T09:00:00Z",   (date -u +%Y-%m-%dT%H:%M:%SZ)
//	  "cartridge": {"nes": {"count": 5, "size_bytes": 61440}},   per-system
//	  "optical":   {...}, "modern": {...},
//	  "exo": {"dos": {"games": 6, "art": 5, "coverage_pct": 83.3}},
//	  "rom_acquire": {"unit": "jupiter-rom-acquire.service",
//	                  "active_state": "inactive"}
//	}
//
// Sources differ from the legacy walk (store aggregates instead of
// find|du; imported metadata instead of grep) but every field keeps its
// meaning: count = games in the system dir, size_bytes = attributed tree
// bytes, art = box-front carriers, coverage_pct = floor(art/games*1000)/10
// (the exact jq arithmetic, 0 when games==0).
package inventory

import (
	"math"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// RomAcquireUnit is the unit name the legacy JSON reported. It is kept
// verbatim for parity even after that unit retires (the state then reads
// "unknown" on hosts without it).
const RomAcquireUnit = "jupiter-rom-acquire.service"

// SystemStat is one bucket entry (legacy jq shape).
type SystemStat struct {
	Count     int64 `json:"count"`
	SizeBytes int64 `json:"size_bytes"`
}

// ExoStat is one curated-collection entry (legacy jq shape).
type ExoStat struct {
	Games       int64   `json:"games"`
	Art         int64   `json:"art"`
	CoveragePct float64 `json:"coverage_pct"`
}

// RomAcquire is the download-unit block (legacy jq shape).
type RomAcquire struct {
	Unit        string `json:"unit"`
	ActiveState string `json:"active_state"`
}

// Doc is the whole inventory document.
type Doc struct {
	GeneratedAt string                `json:"generated_at"`
	Cartridge   map[string]SystemStat `json:"cartridge"`
	Optical     map[string]SystemStat `json:"optical"`
	Modern      map[string]SystemStat `json:"modern"`
	Exo         map[string]ExoStat    `json:"exo"`
	RomAcquire  RomAcquire            `json:"rom_acquire"`
}

// CoveragePct is the legacy jq formula: (art/games*1000 | floor)/10,
// 0 when there are no games (never NaN).
func CoveragePct(art, games int64) float64 {
	if games <= 0 {
		return 0
	}
	return math.Floor(float64(art)/float64(games)*1000) / 10
}

// Build assembles the document from store aggregates plus the live
// rom-acquire state ("" or unknown inputs become "unknown", matching the
// legacy script's systemctl fallback). All maps are non-nil: the legacy
// emitter always produced all five sections.
func Build(summary []store.SystemSummary, exo map[string]store.ExoStat, activeState string, now time.Time) Doc {
	doc := Doc{
		GeneratedAt: now.UTC().Format("2006-01-02T15:04:05Z"),
		Cartridge:   map[string]SystemStat{},
		Optical:     map[string]SystemStat{},
		Modern:      map[string]SystemStat{},
		Exo:         map[string]ExoStat{},
	}
	for _, sys := range summary {
		if sys.Source == store.SourceExo || sys.Bucket == store.ExoBucket {
			continue // exo lives in its own section below
		}
		st := SystemStat{Count: sys.GameCount, SizeBytes: sys.TotalBytes}
		switch sys.Bucket {
		case "optical":
			doc.Optical[sys.Key] = st
		case "modern":
			doc.Modern[sys.Key] = st
		default:
			doc.Cartridge[sys.Key] = st
		}
	}
	for key, s := range exo {
		doc.Exo[key] = ExoStat{Games: s.Games, Art: s.Art, CoveragePct: CoveragePct(s.Art, s.Games)}
	}
	if activeState == "" {
		activeState = "unknown"
	}
	doc.RomAcquire = RomAcquire{Unit: RomAcquireUnit, ActiveState: activeState}
	return doc
}
