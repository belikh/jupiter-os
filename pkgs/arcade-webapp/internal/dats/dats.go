// Package dats is the DAT manager (gauntlet P3, goal 1): it keeps the
// per-system No-Intro/Redump DAT currency flowing — the Go port of
// scripts/fetch-mclean-1g1r-dats.sh, which downloads the Fresh1G1R
// "McLean" 1G1R DATs (one <system>.dat per catalogue system) so igir can
// hash-verify staged sets before promotion instead of promoting as-is.
//
// Semantics ported verbatim from the script:
//   - same URL family: <BaseURL>/<collection>/<DAT basename>, BaseURL
//     overridable (module option) so tests stub the host and never touch
//     GitHub;
//   - same per-system .dat naming into <dir>/<sys>.dat, overwritten in
//     place (idempotent re-fetch);
//   - percent-encoding of the Fresh1G1R filenames (spaces + parens):
//     jq @uri semantics — everything but RFC 3986 unreserved characters
//     is encoded, '/' kept as the collection separator;
//   - failures are per-system WARNINGS that never abort the batch
//     (curl -fsS per system, `|| echo WARNING`).
//
// DATs are non-redistributable (No-Intro/Redump terms): fetched at
// runtime, never committed (ADR-0001) — the committed testdata DATs are
// the self-authored fixture corpus, not these.
package dats

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/scanner"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// DefaultBaseURL is the Fresh1G1R raw-content root the script pins.
// Overridable for tests (module option datFetchBaseUrl).
const DefaultBaseURL = "https://raw.githubusercontent.com/UnluckyForSome/Fresh1G1R/main/daily-1g1r-dat/McLean"

// McLeanDATs maps catalogue system key -> "collection/DAT basename" —
// the explicit mapping from fetch-mclean-1g1r-dats.sh (verified against
// the Fresh1G1R repo 2026-08-18). The catalogue's torrent basenames
// cannot be mechanically mapped to DAT basenames (collection labels
// "Non-Redump"/"RetroAchievements" do not match DAT collections, and a
// few system names differ), so this table IS the mapping. Systems with
// NO exact McLean DAT (wiiu, pcfx, zxspectrum) are intentionally absent;
// verify treats a missing DAT as promote-without-checking for that
// system. Keep in sync with the script until P8 retires it.
var McLeanDATs = map[string]string{
	// No-Intro Nintendo cartridge systems
	"nes":          "no-intro/Nintendo - Nintendo Entertainment System (Headerless) (No-Intro - Fresh1G1R - McLean).dat",
	"snes":         "no-intro/Nintendo - Super Nintendo Entertainment System (No-Intro - Fresh1G1R - McLean).dat",
	"gb":           "no-intro/Nintendo - Game Boy (No-Intro - Fresh1G1R - McLean).dat",
	"gbc":          "no-intro/Nintendo - Game Boy Color (No-Intro - Fresh1G1R - McLean).dat",
	"gba":          "no-intro/Nintendo - Game Boy Advance (No-Intro - Fresh1G1R - McLean).dat",
	"n64":          "no-intro/Nintendo - Nintendo 64 (BigEndian) (No-Intro - Fresh1G1R - McLean).dat",
	"fds":          "no-intro/Nintendo - Family Computer Disk System (FDS) (No-Intro - Fresh1G1R - McLean).dat",
	"virtualboy":   "no-intro/Nintendo - Virtual Boy (No-Intro - Fresh1G1R - McLean).dat",
	"pokemonmini":  "no-intro/Nintendo - Pokemon Mini (No-Intro - Fresh1G1R - McLean).dat",
	"gameandwatch": "no-intro/Nintendo - Game & Watch (No-Intro - Fresh1G1R - McLean).dat",
	"nds":          "no-intro/Nintendo - Nintendo DS (Decrypted) (No-Intro - Fresh1G1R - McLean).dat",
	"dsi":          "no-intro/Nintendo - Nintendo DSi (Decrypted) (No-Intro - Fresh1G1R - McLean).dat",
	"3ds":          "no-intro/Nintendo - Nintendo 3DS (Decrypted) (No-Intro - Fresh1G1R - McLean).dat",
	"new3ds":       "no-intro/Nintendo - New Nintendo 3DS (Decrypted) (No-Intro - Fresh1G1R - McLean).dat",
	// No-Intro Sega
	"sms":       "no-intro/Sega - Master System - Mark III (No-Intro - Fresh1G1R - McLean).dat",
	"megadrive": "no-intro/Sega - Mega Drive - Genesis (No-Intro - Fresh1G1R - McLean).dat",
	"gamegear":  "no-intro/Sega - Game Gear (No-Intro - Fresh1G1R - McLean).dat",
	"sega32x":   "no-intro/Sega - 32X (No-Intro - Fresh1G1R - McLean).dat",
	"sg1000":    "no-intro/Sega - SG-1000 - SC-3000 (No-Intro - Fresh1G1R - McLean).dat",
	// No-Intro NEC
	"pce":        "no-intro/NEC - PC Engine - TurboGrafx-16 (No-Intro - Fresh1G1R - McLean).dat",
	"supergrafx": "no-intro/NEC - PC Engine SuperGrafx (No-Intro - Fresh1G1R - McLean).dat",
	// No-Intro SNK
	"ngp":  "no-intro/SNK - NeoGeo Pocket (No-Intro - Fresh1G1R - McLean).dat",
	"ngpc": "no-intro/SNK - NeoGeo Pocket Color (No-Intro - Fresh1G1R - McLean).dat",
	// No-Intro Commodore / Microsoft / misc cartridge systems
	"c64":           "no-intro/Commodore - Commodore 64 (No-Intro - Fresh1G1R - McLean).dat",
	"vic20":         "no-intro/Commodore - VIC-20 (No-Intro - Fresh1G1R - McLean).dat",
	"plus4":         "no-intro/Commodore - Plus-4 (No-Intro - Fresh1G1R - McLean).dat",
	"amiga":         "no-intro/Commodore - Amiga (No-Intro - Fresh1G1R - McLean).dat",
	"msx":           "no-intro/Microsoft - MSX (No-Intro - Fresh1G1R - McLean).dat",
	"msx2":          "no-intro/Microsoft - MSX2 (No-Intro - Fresh1G1R - McLean).dat",
	"coleco":        "no-intro/Coleco - ColecoVision (No-Intro - Fresh1G1R - McLean).dat",
	"intellivision": "no-intro/Mattel - Intellivision (No-Intro - Fresh1G1R - McLean).dat",
	"vectrex":       "no-intro/GCE - Vectrex (No-Intro - Fresh1G1R - McLean).dat",
	"odyssey2":      "no-intro/Magnavox - Odyssey 2 (No-Intro - Fresh1G1R - McLean).dat",
	"videopac":      "no-intro/Philips - Videopac+ (No-Intro - Fresh1G1R - McLean).dat",
	"apple2":        "no-intro/Apple - II (WOZ) (No-Intro - Fresh1G1R - McLean).dat",
	// No-Intro Atari
	"a2600":    "no-intro/Atari - Atari 2600 (No-Intro - Fresh1G1R - McLean).dat",
	"a5200":    "no-intro/Atari - Atari 5200 (No-Intro - Fresh1G1R - McLean).dat",
	"a7800":    "no-intro/Atari - Atari 7800 (BIN) (No-Intro - Fresh1G1R - McLean).dat",
	"a800":     "no-intro/Atari - 8-bit Family (No-Intro - Fresh1G1R - McLean).dat",
	"lynx":     "no-intro/Atari - Atari Lynx (LYX) (No-Intro - Fresh1G1R - McLean).dat",
	"jaguar":   "no-intro/Atari - Atari Jaguar (J64) (No-Intro - Fresh1G1R - McLean).dat",
	"atari_st": "no-intro/Atari - Atari ST (No-Intro - Fresh1G1R - McLean).dat",
	// Redump optical systems. NOTE: gamecube/wii/ps1/ps2 torrents are
	// labelled "Non-Redump"/"RetroAchievements" but the Fresh1G1R DATs
	// live in redump/.
	"gamecube":   "redump/Nintendo - GameCube (Redump - Fresh1G1R - McLean).dat",
	"wii":        "redump/Nintendo - Wii (Redump - Fresh1G1R - McLean).dat",
	"segacd":     "redump/Sega - Mega CD & Sega CD (Redump - Fresh1G1R - McLean).dat",
	"saturn":     "redump/Sega - Saturn (Redump - Fresh1G1R - McLean).dat",
	"dreamcast":  "redump/Sega - Dreamcast (Redump - Fresh1G1R - McLean).dat",
	"psp":        "redump/Sony - PlayStation Portable (Redump - Fresh1G1R - McLean).dat",
	"ps1":        "redump/Sony - PlayStation (Redump - Fresh1G1R - McLean).dat",
	"ps2":        "redump/Sony - PlayStation 2 (Redump - Fresh1G1R - McLean).dat",
	"jaguar_cd":  "redump/Atari - Jaguar CD Interactive Multimedia System (Redump - Fresh1G1R - McLean).dat",
	"pce_cd":     "redump/NEC - PC Engine CD & TurboGrafx CD (Redump - Fresh1G1R - McLean).dat",
	"pc98":       "redump/NEC - PC-98 series (Redump - Fresh1G1R - McLean).dat",
	"neocd":      "redump/SNK - Neo Geo CD (Redump - Fresh1G1R - McLean).dat",
	"amiga_cd":   "redump/Commodore - Amiga CD (Redump - Fresh1G1R - McLean).dat",
	"amiga_cd32": "redump/Commodore - Amiga CD32 (Redump - Fresh1G1R - McLean).dat",
	"amiga_cdtv": "redump/Commodore - Amiga CDTV (Redump - Fresh1G1R - McLean).dat",
	"fmtowns":    "redump/Fujitsu - FM-Towns (Redump - Fresh1G1R - McLean).dat",
}

// fetchTimeout matches the script's curl --max-time 60 per DAT.
const fetchTimeout = 60 * time.Second

// ErrNotMapped is returned by RefreshSystem for a catalogue system the
// McLean table does not cover (wiiu, pcfx, zxspectrum, …): verify
// deliberately degrades those to promote-without-checking.
var ErrNotMapped = fmt.Errorf("dats: no McLean DAT mapping for system")

// Fetcher downloads McLean DATs into a DAT dir and records dat-fetch runs.
type Fetcher struct {
	BaseURL string
	Dir     string
	Client  *http.Client
	St      *store.Store
	Log     *log.Logger

	mu      sync.Mutex
	running bool // a refresh is in flight (UI state chip)
}

// FetchResult summarizes one refresh batch.
type FetchResult struct {
	Systems  int      `json:"Systems"`  // catalogue systems considered
	Fetched  int      `json:"Fetched"`  // DATs written
	Unmapped int      `json:"Unmapped"` // systems with no McLean DAT (skipped)
	Warnings []string `json:"Warnings"`
}

// Running reports whether a refresh is in flight (for the UI state chip).
func (f *Fetcher) Running() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.running
}

// Refresh fetches every mapped system's DAT. Per-system failures become
// warnings (the script's `|| echo WARNING` — never abort the batch);
// unmapped systems are counted, not warned about (they are a deliberate
// non-set). Recorded as one dat-fetch run.
func (f *Fetcher) Refresh(ctx context.Context, systems []store.SystemRow) FetchResult {
	f.mu.Lock()
	if f.running {
		f.mu.Unlock()
		return FetchResult{Warnings: []string{"a DAT refresh is already running"}}
	}
	f.running = true
	f.mu.Unlock()
	defer func() {
		f.mu.Lock()
		f.running = false
		f.mu.Unlock()
	}()

	runID, err := f.St.StartRun("dat-fetch")
	if err != nil {
		f.logf("record run: %v", err)
	}
	var res FetchResult
	for _, sys := range systems {
		res.Systems++
		rel, ok := McLeanDATs[sys.Key]
		if !ok {
			res.Unmapped++
			continue
		}
		dst := filepath.Join(f.Dir, sys.Key+".dat")
		u := f.BaseURL + "/" + encodePath(rel)
		if err := f.fetchOne(ctx, u, dst); err != nil {
			res.Warnings = append(res.Warnings, fmt.Sprintf("%s: %v", sys.Key, err))
			f.logf("%s: fetch failed: %v", sys.Key, err)
			continue
		}
		res.Fetched++
		// Refresh the currency card immediately: parse the new header
		// into dat_info so the UI updates without waiting for a rescan.
		if info, err := scanner.ReadDAT(dst); err == nil {
			info.SystemKey = sys.Key
			if err := f.St.SetDATInfo(*info); err != nil {
				res.Warnings = append(res.Warnings, fmt.Sprintf("%s: persist dat info: %v", sys.Key, err))
			}
		} else {
			res.Warnings = append(res.Warnings, fmt.Sprintf("%s: fetched DAT unparseable: %v", sys.Key, err))
		}
	}
	if runID != 0 {
		status := "ok"
		detail, _ := json.Marshal(res)
		if err := f.St.FinishRun(runID, status, string(detail)); err != nil {
			f.logf("finish run: %v", err)
		}
	}
	return res
}

// RefreshSystem fetches one system's DAT on demand. Returns
// ErrNotMapped for systems the table does not cover. Also recorded as a
// dat-fetch run (single-system batch) so the audit trail is complete.
func (f *Fetcher) RefreshSystem(ctx context.Context, sys store.SystemRow) error {
	rel, ok := McLeanDATs[sys.Key]
	if !ok {
		return ErrNotMapped
	}
	f.mu.Lock()
	if f.running {
		f.mu.Unlock()
		return fmt.Errorf("dats: a DAT refresh is already running")
	}
	f.running = true
	f.mu.Unlock()
	defer func() {
		f.mu.Lock()
		f.running = false
		f.mu.Unlock()
	}()

	runID, err := f.St.StartRun("dat-fetch")
	if err != nil {
		f.logf("record run: %v", err)
	}
	dst := filepath.Join(f.Dir, sys.Key+".dat")
	u := f.BaseURL + "/" + encodePath(rel)
	if err := f.fetchOne(ctx, u, dst); err != nil {
		if runID != 0 {
			_ = f.St.FinishRun(runID, "error", sys.Key+": "+err.Error())
		}
		return err
	}
	if info, err := scanner.ReadDAT(dst); err == nil {
		info.SystemKey = sys.Key
		_ = f.St.SetDATInfo(*info)
	}
	if runID != 0 {
		detail, _ := json.Marshal(FetchResult{Systems: 1, Fetched: 1})
		_ = f.St.FinishRun(runID, "ok", string(detail))
	}
	return nil
}

// fetchOne downloads url into dst atomically: a torn download must never
// replace a good DAT (the script's curl -o is fine for a shell tool; a
// long-running app writes temp + renames).
func (f *Fetcher) fetchOne(ctx context.Context, url, dst string) error {
	ctx, cancel := context.WithTimeout(ctx, fetchTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := f.client().Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close() //nolint:errcheck // read-only
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(dst), "."+filepath.Base(dst)+".tmp*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) //nolint:errcheck // no-op after successful rename
	if _, err := io.Copy(tmp, resp.Body); err != nil {
		tmp.Close() //nolint:errcheck // best effort
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, dst)
}

func (f *Fetcher) client() *http.Client {
	if f.Client != nil {
		return f.Client
	}
	return http.DefaultClient
}

func (f *Fetcher) logf(format string, args ...any) {
	if f.Log != nil {
		f.Log.Printf("dats: "+format, args...)
	}
}

// encodePath percent-encodes a "collection/DAT basename" path the way the
// script's jq @uri does: every byte outside RFC 3986's unreserved set
// (ALPHA / DIGIT / "-" / "." / "_" / "~") is hex-encoded — Fresh1G1R
// filenames contain spaces and parens — while "/" stays a real separator
// (the script pipes jq's output through sed 's|%2F|/|g').
func encodePath(rel string) string {
	var b strings.Builder
	for i := 0; i < len(rel); i++ {
		c := rel[i]
		switch {
		case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9',
			c == '-', c == '.', c == '_', c == '~', c == '/':
			b.WriteByte(c)
		default:
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

// URLFor returns the fetch URL for a mapped system ("" when unmapped) —
// used by the UI to show where a DAT comes from.
func URLFor(baseURL, systemKey string) string {
	rel, ok := McLeanDATs[systemKey]
	if !ok {
		return ""
	}
	return baseURL + "/" + encodePath(rel)
}
