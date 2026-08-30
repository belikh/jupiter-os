// Package dats is the DAT manager (gauntlet P3, goal 1): it keeps the
// per-system No-Intro/Redump DAT currency flowing — the Go port of
// scripts/fetch-mclean-1g1r-dats.sh, which downloads the Fresh1G1R
// "McLean" 1G1R DATs (one <system>.dat per catalogue system) so igir can
// hash-verify staged sets before promotion instead of promoting as-is.
//
// Remediation W4b (plan §6.G) makes the pin REAL — the DAT supply chain
// is content-addressed end to end:
//
//   - every fetch goes to a COMMIT-PINNED raw URL
//     (<BaseURL>/<full commit>/<subdir>/<collection path>), never the
//     mutable branch ref — the same commit cannot serve two different
//     byte streams without the CDN breaking its own contract;
//   - <Dir>/dat-lock.json is the content-addressed lock: per-system
//     source_commit (full SHA), bytes_sha256, rom_count, fetched_at. A
//     fetch at a commit the lock already pins MUST reproduce the locked
//     bytes or the generation is REFUSED (torn download, mutated cache);
//   - every ACCEPTED generation appends one dat_versions row (store
//     schema v11) — the append-only ledger that answers "what attested
//     what, and when";
//   - promotion refuses to run against a DAT whose on-disk bytes no
//     longer match its lock entry (CheckLock — the igir runner calls it
//     immediately before exec): a DAT swapped on disk after the lock
//     attested it is untrusted input, never a verify baseline;
//   - the liveness alarm (Liveness) pages on the measured asymmetry:
//     no-intro fleet frozen >21 days while redump fetched <14 days ago —
//     the broken-leg detector for "the upstream feed died nine weeks
//     ago and nobody noticed".
//
// Semantics ported from the script (unchanged):
//   - same per-system .dat naming into <dir>/<sys>.dat;
//   - percent-encoding of the Fresh1G1R filenames (spaces + parens):
//     jq @uri semantics — everything but RFC 3986 unreserved characters
//     is encoded, '/' kept as the collection separator;
//   - failures are per-system WARNINGS that never abort the batch
//     (curl -fsS per system, `|| echo WARNING`).
//
// DATs are non-redistributable (No-Intro/Redump terms): fetched at
// runtime, never committed (ADR-0001) — the committed testdata DATs are
// the self-authored fixture corpus, not these. The LOCK (hashes and
// commit IDs only, no DAT content) carries no redistributable bytes.
package dats

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
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

// DefaultBaseURL is the Fresh1G1R raw-content root. The REF is appended
// by the fetcher (commit-pinned since W4b): fetch URLs are
// <BaseURL>/<commit>/<DATSubdir>/<encoded collection path>. Overridable
// for tests (module option datFetchBaseUrl).
const DefaultBaseURL = "https://raw.githubusercontent.com/UnluckyForSome/Fresh1G1R"

// DefaultDATSubdir is the in-repo path of the McLean DAT tree under any
// given ref.
const DefaultDATSubdir = "daily-1g1r-dat/McLean"

// DefaultCommitURL resolves the Fresh1G1R ref to a full commit SHA (the
// GitHub REST commits endpoint; the response's top-level "sha"). One
// call per refresh batch — every DAT in the batch is then fetched at
// that immutable commit. Overridable for tests (module option
// datCommitUrl).
const DefaultCommitURL = "https://api.github.com/repos/UnluckyForSome/Fresh1G1R/commits/main"

// LockFileName is the content-addressed lock's basename inside Dir.
const LockFileName = "dat-lock.json"

// Liveness thresholds (plan §6.G, the measured broken-leg detector): the
// alarm fires when the no-intro fleet's newest accepted generation is
// older than NoIntroFrozenDays while redump's newest is younger than
// RedumpFreshDays — upstream moved for one family and not the other.
const (
	NoIntroFrozenDays = 21
	RedumpFreshDays   = 14
)

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
	"a800":     "no-intro/Atari - Atari 8-bit Family (No-Intro - Fresh1G1R - McLean).dat",
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

// LockEntry is one system's lock record — the content-addressed pin.
type LockEntry struct {
	SourceCommit string `json:"source_commit"` // full 40-hex Fresh1G1R commit SHA
	BytesSHA256  string `json:"bytes_sha256"`  // hex sha256 of the DAT bytes
	RomCount     int    `json:"rom_count"`
	FetchedAt    string `json:"fetched_at"` // RFC3339
}

// Lock is the on-disk dat-lock.json document.
type Lock struct {
	Systems map[string]LockEntry `json:"systems"`
}

// LockMismatch describes a DAT whose on-disk bytes no longer match its
// lock entry — the promotion-refused signal (W4b acceptance).
type LockMismatch struct {
	SystemKey   string
	Entry       LockEntry
	OnDiskSHA   string
	OnDiskBytes int64
}

func (m *LockMismatch) Error() string {
	return fmt.Sprintf("dats: %s.dat fails its dat-lock entry (locked %s at commit %s, on disk %s, %d bytes) — refusing to use it",
		m.SystemKey, m.Entry.BytesSHA256, shortSHA(m.Entry.SourceCommit), m.OnDiskSHA, m.OnDiskBytes)
}

func shortSHA(s string) string {
	if len(s) > 12 {
		return s[:12]
	}
	return s
}

// Fetcher downloads McLean DATs into a DAT dir and records dat-fetch runs.
type Fetcher struct {
	// BaseURL is the raw-content root WITHOUT a ref (see DefaultBaseURL).
	BaseURL string
	// CommitURL resolves the moving ref to a full commit SHA (see
	// DefaultCommitURL). Empty disables resolution — the lock's pinned
	// commit is used when present, else every mapped system warns.
	CommitURL string
	// DATSubdir overrides DefaultDATSubdir (tests relocate the tree).
	DATSubdir string
	Dir       string
	Client    *http.Client
	St        *store.Store
	Log       *log.Logger

	mu      sync.Mutex
	running bool // a refresh is in flight (UI state chip)
}

// FetchResult summarizes one refresh batch.
type FetchResult struct {
	Systems  int      `json:"Systems"`  // catalogue systems considered
	Fetched  int      `json:"Fetched"`  // DATs left current (new generation or verified unchanged)
	Unmapped int      `json:"Unmapped"` // systems with no McLean DAT (skipped)
	Warnings []string `json:"Warnings"`
}

// Running reports whether a refresh is in flight (for the UI state chip).
func (f *Fetcher) Running() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.running
}

func (f *Fetcher) datSubdir() string {
	if f.DATSubdir != "" {
		return f.DATSubdir
	}
	return DefaultDATSubdir
}

// systemURL builds the commit-pinned fetch URL for one system.
func (f *Fetcher) systemURL(commit, systemKey string) string {
	rel, ok := McLeanDATs[systemKey]
	if !ok {
		return ""
	}
	return f.BaseURL + "/" + commit + "/" + encodePath(f.datSubdir()+"/"+rel)
}

// resolveCommit fetches the ref's current full SHA. Non-2xx/parse
// failures return the error; callers fall back to the lock's pin.
func (f *Fetcher) resolveCommit(ctx context.Context) (string, error) {
	u := f.CommitURL
	if u == "" {
		u = DefaultCommitURL
	}
	ctx, cancel := context.WithTimeout(ctx, fetchTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return "", err
	}
	resp, err := f.client().Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close() //nolint:errcheck // read-only
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("commit resolve HTTP %d", resp.StatusCode)
	}
	var out struct {
		SHA string `json:"sha"`
	}
	// A hostile/stub host could serve an unbounded document; cap it.
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&out); err != nil {
		return "", err
	}
	if len(out.SHA) != 40 {
		return "", fmt.Errorf("commit resolve returned a non-40-hex sha %q", out.SHA)
	}
	return out.SHA, nil
}

// ReadLock loads (or initialises) the lock document for a DAT dir. A
// missing file is an empty lock, never an error — the bootstrap state.
func ReadLock(dir string) (*Lock, error) {
	b, err := os.ReadFile(filepath.Join(dir, LockFileName))
	if errors.Is(err, os.ErrNotExist) {
		return &Lock{Systems: map[string]LockEntry{}}, nil
	}
	if err != nil {
		return nil, err
	}
	var l Lock
	if err := json.Unmarshal(b, &l); err != nil {
		return nil, fmt.Errorf("dats: %s unparseable: %w", LockFileName, err)
	}
	if l.Systems == nil {
		l.Systems = map[string]LockEntry{}
	}
	return &l, nil
}

// WriteLock atomically replaces the lock document (temp + rename — a
// torn write must never corrupt the pin).
func WriteLock(dir string, l *Lock) error {
	if l.Systems == nil {
		l.Systems = map[string]LockEntry{}
	}
	b, err := json.MarshalIndent(l, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, "."+LockFileName+".tmp*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) //nolint:errcheck // no-op after successful rename
	if _, err := tmp.Write(append(b, '\n')); err != nil {
		tmp.Close() //nolint:errcheck // error path
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, filepath.Join(dir, LockFileName))
}

// CheckLock hashes <dir>/<systemKey>.dat and compares it against the
// lock entry. nil means: no lock entry (bootstrap — nothing attested
// yet, callers proceed on their own policy) or bytes match. A
// *LockMismatch means the on-disk DAT is NOT the bytes the lock
// attested — promotion against it must be refused (W4b acceptance).
func CheckLock(dir, systemKey string) error {
	l, err := ReadLock(dir)
	if err != nil {
		return err
	}
	entry, ok := l.Systems[systemKey]
	if !ok {
		return nil
	}
	path := filepath.Join(dir, systemKey+".dat")
	sum, size, err := sha256File(path)
	if err != nil {
		return err
	}
	if sum != entry.BytesSHA256 {
		return &LockMismatch{SystemKey: systemKey, Entry: entry, OnDiskSHA: sum, OnDiskBytes: size}
	}
	return nil
}

func sha256File(path string) (hexSum string, size int64, err error) {
	f, err := os.Open(path)
	if err != nil {
		return "", 0, err
	}
	defer f.Close() //nolint:errcheck // read-only
	h := sha256.New()
	n, err := io.Copy(h, f)
	if err != nil {
		return "", 0, err
	}
	return hex.EncodeToString(h.Sum(nil)), n, nil
}

// Refresh fetches every mapped system's DAT. Per-system failures become
// warnings (the script's `|| echo WARNING` — never abort the batch);
// unmapped systems are counted, not warned about (they are a deliberate
// non-set). Recorded as one dat-fetch run. Every DAT in the batch is
// fetched at ONE commit-pinned ref resolved up front; each accepted
// generation appends a dat_versions row and updates the lock.
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

	commit, cerr := f.resolveCommit(ctx)
	lock, lerr := ReadLock(f.Dir)
	if lerr != nil {
		lock = &Lock{Systems: map[string]LockEntry{}}
	}
	if cerr != nil {
		if pinned, ok := pinnedCommit(lock); ok {
			f.logf("commit resolve failed (%v) — falling back to the lock's pin %s", cerr, shortSHA(pinned))
			commit = pinned
		} else {
			commit = ""
		}
	}

	var res FetchResult
	for _, sys := range systems {
		res.Systems++
		rel, ok := McLeanDATs[sys.Key]
		if !ok {
			res.Unmapped++
			continue
		}
		if commit == "" {
			res.Warnings = append(res.Warnings, fmt.Sprintf("%s: no source commit (resolve failed and no lock pin)", sys.Key))
			continue
		}
		if _, err := f.fetchSystemAt(ctx, sys.Key, rel, commit, lock); err != nil {
			res.Warnings = append(res.Warnings, fmt.Sprintf("%s: %v", sys.Key, err))
			f.logf("%s: fetch failed: %v", sys.Key, err)
			continue
		}
		// fetchSystemAt's changed flag is false for "already AT the
		// locked generation" (verified unchanged) — the DAT is current
		// either way, so both paths count.
		res.Fetched++
	}
	if err := WriteLock(f.Dir, lock); err != nil {
		res.Warnings = append(res.Warnings, fmt.Sprintf("dat-lock: %v", err))
		f.logf("lock write: %v", err)
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
	commit, cerr := f.resolveCommit(ctx)
	lock, lerr := ReadLock(f.Dir)
	if lerr != nil {
		lock = &Lock{Systems: map[string]LockEntry{}}
	}
	if cerr != nil {
		if pinned, ok := pinnedCommit(lock); ok {
			commit = pinned
		} else {
			if runID != 0 {
				_ = f.St.FinishRun(runID, "error", sys.Key+": "+cerr.Error())
			}
			return cerr
		}
	}
	if _, err := f.fetchSystemAt(ctx, sys.Key, rel, commit, lock); err != nil {
		if runID != 0 {
			_ = f.St.FinishRun(runID, "error", sys.Key+": "+err.Error())
		}
		return err
	}
	if err := WriteLock(f.Dir, lock); err != nil {
		f.logf("lock write: %v", err)
	}
	if runID != 0 {
		detail, _ := json.Marshal(FetchResult{Systems: 1, Fetched: 1})
		_ = f.St.FinishRun(runID, "ok", string(detail))
	}
	return nil
}

// pinnedCommit picks a commit from an existing lock (the newest
// fetched_at entry) — the fallback when ref resolution fails, so a
// GitHub API outage degrades the refresh to the last-attested
// generation instead of killing DAT currency outright.
func pinnedCommit(lock *Lock) (string, bool) {
	best := ""
	var bestAt time.Time
	for _, e := range lock.Systems {
		if len(e.SourceCommit) != 40 {
			continue
		}
		at, err := time.Parse(time.RFC3339, e.FetchedAt)
		if err != nil {
			at = time.Time{}
		}
		if best == "" || at.After(bestAt) {
			best, bestAt = e.SourceCommit, at
		}
	}
	return best, best != ""
}

// fetchSystemAt performs one system's content-addressed fetch at commit:
// download to temp, hash, gate against the lock, install, append the
// ledger row, update the lock entry in memory. Returns accepted=false
// (nil error) when the system is already AT the locked generation —
// idempotent re-fetch, no new dat_versions row ("one commit per accepted
// generation").
func (f *Fetcher) fetchSystemAt(ctx context.Context, systemKey, rel, commit string, lock *Lock) (bool, error) {
	dst := filepath.Join(f.Dir, systemKey+".dat")
	u := f.BaseURL + "/" + commit + "/" + encodePath(f.datSubdir()+"/"+rel)
	body, err := f.download(ctx, u)
	if err != nil {
		return false, err
	}
	sum := sha256.Sum256(body)
	sumHex := hex.EncodeToString(sum[:])

	if entry, ok := lock.Systems[systemKey]; ok && entry.SourceCommit == commit && entry.BytesSHA256 != sumHex {
		// The same commit served different bytes than the lock
		// attested: torn download, mutated cache, or a broken CDN.
		// REFUSE the generation — the file is never installed, the
		// lock entry and ledger stay at the last good generation.
		return false, &LockMismatch{SystemKey: systemKey, Entry: entry, OnDiskSHA: sumHex, OnDiskBytes: int64(len(body))}
	}

	info, perr := scanner.ReadDATBytes(body)
	if perr != nil {
		return false, fmt.Errorf("fetched DAT unparseable: %w", perr)
	}
	info.SystemKey = systemKey

	if entry, ok := lock.Systems[systemKey]; ok && entry.SourceCommit == commit && entry.BytesSHA256 == sumHex {
		// Already at the locked generation. Re-parse into dat_info so
		// the currency card refreshes without a rescan, but append no
		// new ledger row and rewrite the file only when its bytes
		// actually differ on disk (idempotent).
		if diskSum, _, derr := sha256File(dst); derr != nil || diskSum != sumHex {
			if err := writeFileAtomic(dst, body); err != nil {
				return false, err
			}
		}
		if err := f.St.SetDATInfo(*info); err != nil {
			return false, fmt.Errorf("persist dat info: %w", err)
		}
		return false, nil
	}

	// New accepted generation: install, ledger, lock.
	if err := writeFileAtomic(dst, body); err != nil {
		return false, err
	}
	if err := f.St.SetDATInfo(*info); err != nil {
		return false, fmt.Errorf("persist dat info: %w", err)
	}
	now := time.Now().UTC().Format(time.RFC3339)
	if err := f.St.AppendDATVersion(store.DATVersion{
		SystemKey:    systemKey,
		SourceCommit: commit,
		BytesSHA256:  sumHex,
		RomCount:     info.RomCount,
		DatName:      info.DatName,
		Version:      info.Version,
		Date:         info.Date,
		FetchedAt:    now,
	}); err != nil {
		return false, fmt.Errorf("append dat_versions: %w", err)
	}
	lock.Systems[systemKey] = LockEntry{
		SourceCommit: commit,
		BytesSHA256:  sumHex,
		RomCount:     info.RomCount,
		FetchedAt:    now,
	}
	f.logf("%s: accepted generation %s (%d roms, %d bytes)", systemKey, shortSHA(commit), info.RomCount, len(body))
	return true, nil
}

// download fetches url into memory with the script's per-DAT timeout.
// DATs are tens-of-MB XML; a 512 MiB cap is a hostile-host guard, not a
// real limit.
func (f *Fetcher) download(ctx context.Context, url string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, fetchTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := f.client().Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close() //nolint:errcheck // read-only
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, 512<<20))
}

func writeFileAtomic(dst string, body []byte) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(dst), "."+filepath.Base(dst)+".tmp*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) //nolint:errcheck // no-op after successful rename
	if _, err := tmp.Write(body); err != nil {
		tmp.Close() //nolint:errcheck // error path
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, dst)
}

// Liveness is the asymmetry alarm (plan §6.G): frozen reports whether
// the no-intro fleet's newest accepted generation is older than
// NoIntroFrozenDays while redump's newest is younger than
// RedumpFreshDays — the measured signature of "the no-intro feed died
// and nobody noticed" (the nine-week silent freeze). detail is human
// prose for the page/log; "" when healthy.
func Liveness(st *store.Store, now time.Time) (frozen bool, detail string) {
	newest, err := st.NewestDATVersionBySystem()
	if err != nil {
		return false, ""
	}
	var noIntroNewest, redumpNewest time.Time
	for sys, v := range newest {
		rel, ok := McLeanDATs[sys]
		if !ok || v == nil {
			continue
		}
		at, err := time.Parse(time.RFC3339, v.FetchedAt)
		if err != nil {
			continue
		}
		if strings.HasPrefix(rel, "no-intro/") && at.After(noIntroNewest) {
			noIntroNewest = at
		}
		if strings.HasPrefix(rel, "redump/") && at.After(redumpNewest) {
			redumpNewest = at
		}
	}
	if noIntroNewest.IsZero() || redumpNewest.IsZero() {
		return false, "" // not enough history to judge the asymmetry
	}
	noIntroAge := now.Sub(noIntroNewest).Hours() / 24
	redumpAge := now.Sub(redumpNewest).Hours() / 24
	if noIntroAge > NoIntroFrozenDays && redumpAge < RedumpFreshDays {
		return true, fmt.Sprintf(
			"DAT liveness alarm: no-intro fleet frozen for %dd (> %dd) while redump fetched %dd ago (< %dd) — the no-intro feed is the broken leg; check the Fresh1G1R repo",
			int(noIntroAge), NoIntroFrozenDays, int(redumpAge), RedumpFreshDays)
	}
	return false, ""
}

// Liveness is the Fetcher-bound form of the package alarm (the verify
// page calls it on every poll; the scheduled refresh in main logs it).
func (f *Fetcher) Liveness(now time.Time) (frozen bool, detail string) {
	if f.St == nil {
		return false, ""
	}
	return Liveness(f.St, now)
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

// URLFor returns the COMMIT-PINNED fetch URL for a mapped system (""
// when unmapped) — used by the UI to show exactly where a DAT comes
// from. The commit shown is the lock's newest pin; an unlocked system
// renders the ref placeholder "<commit>" so the shape stays honest.
func URLFor(baseURL, systemKey string) string {
	rel, ok := McLeanDATs[systemKey]
	if !ok {
		return ""
	}
	return baseURL + "/<commit>/" + encodePath(DefaultDATSubdir+"/"+rel)
}
