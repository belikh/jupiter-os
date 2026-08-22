// Package scrape is the Skyscraper runner (gauntlet plan §2): a Go port of
// scripts/cartridge-scrape.sh's per-platform body — resource gather
// (ScreenScraper primary / configured source gap-fill) then the pegasus
// compose, all into the shared resource cache, finishing with the scanner's
// coverage-flag refresh.
//
// Script semantics preserved EXACTLY (the script is the spec):
//
//   - Missing games-tree dir or zero ROM files -> skip (idempotent; the ROM
//     count guards against a stray dotfile zeroing the cache).
//   - Per-pass failures are LOGGED AND CONTINUED, never batch aborts.
//   - Credential FILES are read at call time and their contents are passed
//     straight to the scraper via -u — contents are never logged, never
//     embedded in an error, never persisted anywhere else.
package scrape

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/scanner"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// passTimeout caps every Skyscraper invocation (each phase, not the batch).
const passTimeout = 30 * time.Minute

// romSuffixes is the ROM-count filter (cartridge-scrape.sh's $ROM_RE,
// case-insensitive, matched against file suffixes recursively).
var romSuffixes = []string{
	".zip", ".nes", ".sfc", ".gb", ".gbc", ".gba",
	".n64", ".cue", ".bin", ".chd", ".iso",
}

// defaultSource is cartridge-scrape.sh's positional <source> default.
const defaultSource = "thegamesdb"

// Driver anchors scraping at the binaries, trees and credential files it
// needs. Credential fields hold PATHS, never values (read at call time —
// activation-time sops secrets).
type Driver struct {
	BinPath                string // Skyscraper executable ("" = not configured)
	CacheDir               string // Skyscraper resource-cache root
	Source                 string // secondary/fallback scraper ("" = thegamesdb)
	ScreenscraperCredsFile string // optional path to user:password creds
	TGDBKeyFile            string // optional path to TheGamesDB apikey
	Store                  *store.Store
	// Bucket roots: the games tree is <root>/<sys>, routed by the
	// catalogue row's Bucket column (igir's bucketRoot mapping).
	CartridgeRoot string
	OpticalRoot   string
	ModernRoot    string
}

// Configured reports whether the driver has everything it must have.
func (d *Driver) Configured() bool {
	return d.BinPath != "" && d.CacheDir != "" && d.Store != nil
}

func (d *Driver) bucketRoot(bucket string) string {
	switch bucket {
	case "optical":
		return d.OpticalRoot
	case "modern":
		return d.ModernRoot
	default:
		return d.CartridgeRoot
	}
}

// ScrapeSystem runs the full three-pass flow for one system.
func (d *Driver) ScrapeSystem(systemKey string) error {
	return d.scrape(systemKey, "")
}

// ScrapeGame runs the same flow restricted to one ROM (--startat/--endat on
// the gather passes; the pegasus compose still exports the whole platform,
// exactly like a single-game rerun of the script).
func (d *Driver) ScrapeGame(systemKey, relPath string) error {
	if relPath == "" {
		return errors.New("scrape: empty game path")
	}
	return d.scrape(systemKey, relPath)
}

func (d *Driver) scrape(systemKey, startAt string) error {
	if !d.Configured() {
		return errors.New("scrape: driver not configured")
	}
	sys, err := d.lookupSystem(systemKey)
	if err != nil {
		return err
	}
	dir := filepath.Join(d.bucketRoot(sys.Bucket), sys.Key)

	// Idempotent skips (the script's first two guards).
	if fi, serr := os.Stat(dir); serr != nil || !fi.IsDir() {
		logf("%s: games dir missing (%s); skipping", systemKey, dir)
		return nil
	}
	if romCount(dir) == 0 {
		logf("%s: no ROM files in %s; skipping to protect Skyscraper cache", systemKey, dir)
		return nil
	}

	// Launch line: retroarch+core wins, else the dedicated emulator, else
	// there is nothing playable to seed — refuse loudly.
	var launch string
	switch {
	case sys.Core != "" && sys.Core != "-":
		launch = "jupiter-retroarch -L " + sys.Core
	case sys.Emulator != "":
		launch = "jupiter-" + sys.Emulator
	default:
		return fmt.Errorf("scrape: %s: no core or emulator mapped; cannot build launch line", systemKey)
	}

	skyPlatform := sys.Key
	if sys.SkyHandle != "" {
		skyPlatform = sys.SkyHandle
	}
	cache := filepath.Join(d.CacheDir, skyPlatform)
	if err := os.MkdirAll(cache, 0o755); err != nil {
		return fmt.Errorf("scrape: %s: cache dir: %w", systemKey, err)
	}

	// Per-system Skyscraper config. The [pegasus] launch line becomes the
	// collection's `launch:` field in metadata.pegasus.txt. {file.path} is
	// the Pegasus token for the ROM's path, wrapped in BACKSLASH-escaped
	// quotes (literal \" bytes in the file): Qt's INI parser strips a bare
	// quote pair, which would leave the token unquoted and word-split
	// No-Intro paths at launch time — see cartridge-scrape.sh.
	iniPath := filepath.Join(d.CacheDir, "config-"+systemKey+".ini")
	ini := fmt.Sprintf("[pegasus]\nlaunch=%s \\\"{file.path}\"\n", launch)
	if err := os.WriteFile(iniPath, []byte(ini), 0o644); err != nil {
		return fmt.Errorf("scrape: %s: write config: %w", systemKey, err)
	}

	source := d.Source
	if source == "" {
		source = defaultSource
	}

	anyOK := false
	haveSS := false

	// Pass A: ScreenScraper primary — CRC-exact for zips via unpack, -t 1
	// for the free-tier thread cap. Only when the creds FILE is readable.
	if creds, cerr := readCreds(d.ScreenscraperCredsFile); cerr == nil {
		haveSS = true
		args := []string{
			"-p", skyPlatform,
			"-s", "screenscraper",
			"-i", dir,
			"-d", cache,
			"-c", iniPath,
			"-u", creds, // contents: exec argv only, never logged
			"-t", "1",
			"--flags", "unattend,unpack",
		}
		args = addWindow(args, startAt)
		if err := d.runPass(systemKey, "screenscraper", args); err != nil {
			logf("%s: %v (continuing)", systemKey, err)
		} else {
			anyOK = true
		}
	}

	// Pass B: configured source — onlymissing gap-fill when ScreenScraper
	// ran (a fuzzy filename match must not overwrite a checksum match),
	// full scrape as primary otherwise. TheGamesDB benefits from -u.
	flags := "unattend"
	if haveSS {
		flags = "unattend,onlymissing"
	}
	args := []string{
		"-p", skyPlatform,
		"-s", source,
		"-i", dir,
		"-d", cache,
		"-c", iniPath,
	}
	if source == defaultSource {
		if key, cerr := readCreds(d.TGDBKeyFile); cerr == nil {
			args = append(args, "-u", key)
		}
	}
	args = append(args, "--flags", flags)
	args = addWindow(args, startAt)
	if err := d.runPass(systemKey, source, args); err != nil {
		logf("%s: %v (continuing)", systemKey, err)
	} else {
		anyOK = true
	}

	// Pass C: compose Pegasus frontend files from the cache. -d MUST point
	// at the same cache the gather passes wrote (otherwise Skyscraper
	// reads its empty default and emits zero entries); -g drops the
	// metadata next to the ROMs.
	args = []string{
		"-p", skyPlatform,
		"-f", "pegasus",
		"-i", dir,
		"-d", cache,
		"-g", dir,
		"-c", iniPath,
		"--flags", "unattend",
	}
	if err := d.runPass(systemKey, "pegasus", args); err != nil {
		logf("%s: %v (continuing)", systemKey, err)
	} else {
		anyOK = true
	}

	// Coverage refresh after ANY successful pass — best effort; a scanner
	// hiccup must not fail an otherwise-successful scrape.
	if anyOK {
		if err := scanner.ApplyCacheFlags(d.Store, sys, dir, cache); err != nil {
			logf("%s: coverage refresh: %v", systemKey, err)
		}
	}
	return nil
}

// lookupSystem resolves one catalogue row (Systems() is the store's only
// reader; igir maps by key the same way).
func (d *Driver) lookupSystem(systemKey string) (store.SystemRow, error) {
	systems, err := d.Store.Systems()
	if err != nil {
		return store.SystemRow{}, fmt.Errorf("scrape: systems: %w", err)
	}
	for _, s := range systems {
		if s.Key == systemKey {
			return s, nil
		}
	}
	return store.SystemRow{}, fmt.Errorf("scrape: unknown system %q (not in catalogue)", systemKey)
}

// readCreds reads a credential FILE at call time and trims it the way the
// script's $(cat …) did. Errors carry the path only — contents never reach
// a log or an error.
func readCreds(path string) (string, error) {
	if path == "" {
		return "", errors.New("no credentials file configured")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("credentials file %s unreadable: %w", path, err)
	}
	return strings.TrimSpace(string(b)), nil
}

// addWindow restricts a gather pass to one ROM (--startat/--endat).
func addWindow(args []string, startAt string) []string {
	if startAt == "" {
		return args
	}
	return append(args, "--startat", startAt, "--endat", startAt)
}

// runPass execs BinPath with the given args, mirroring runner.go: combined
// output is folded (tail-first) into the returned error, never dumped raw.
func (d *Driver) runPass(systemKey, name string, args []string) error {
	ctx, cancel := context.WithTimeout(context.Background(), passTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, d.BinPath, args...)
	// Skyscraper is Qt6; a headless service cannot construct a platform
	// surface without offscreen (cartridge-scrape.sh's unit environment).
	cmd.Env = append(os.Environ(), "QT_QPA_PLATFORM=offscreen")
	out, err := cmd.CombinedOutput()
	tail := strings.TrimSpace(string(out))
	if len(tail) > 400 {
		tail = "…" + tail[len(tail)-400:]
	}
	if err != nil {
		return fmt.Errorf("%s pass failed (%v): %s", name, err, tail)
	}
	logf("%s: %s pass ok", systemKey, name)
	return nil
}

// romCount counts regular ROM-suffixed files anywhere below dir — counting
// ACTUAL ROM files, not "any file" (a stray .gitkeep must not falsely pass;
// recursive so nested layouts count too, like the script's find).
func romCount(dir string) int {
	count := 0
	_ = filepath.WalkDir(dir, func(_ string, entry fs.DirEntry, err error) error {
		if err != nil {
			return nil // unreadable entries read as absent, like find's
		}
		if entry.IsDir() || !entry.Type().IsRegular() {
			return nil
		}
		ext := strings.ToLower(filepath.Ext(entry.Name()))
		for _, want := range romSuffixes {
			if ext == want {
				count++
				break
			}
		}
		return nil
	})
	return count
}

func logf(format string, args ...any) {
	log.Printf("scrape: "+format, args...)
}
