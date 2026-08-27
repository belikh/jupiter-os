// arcade-webapp — entry point of the jupiterOS Arcade webapp (gauntlet
// plan Phase 1: pipeline dashboard).
//
// Configuration is env-driven; modules/services/arcade-webapp.nix owns the
// real options and maps them onto these. Path options are all runtime
// reads — secret material, when later phases need it, arrives as file
// PATHS (sops-decrypted at activation), never inline values.
package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/aria2"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/dats"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/generate"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/igir"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/pipeline"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/scanner"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/scrape"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/web"
)

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// secretPaths are the sops-decrypted secret FILE paths handed in by the
// NixOS module. P1 only records their presence (never their content — the
// values are read at runtime by the phases that need them: aria2 RPC in
// P2, ScreenScraper/TGDB in P5).
type secretPaths struct {
	Aria2RPC      string
	ScreenScraper string
	TGDBAPIKey    string
}

func main() {
	addr := envOr("ARCADE_WEBAPP_ADDR", ":8094")

	secrets := secretPaths{
		Aria2RPC:      envOr("ARCADE_WEBAPP_ARIA2_SECRET_FILE", ""),
		ScreenScraper: envOr("ARCADE_WEBAPP_SCREENSCRAPER_CREDS_FILE", ""),
		TGDBAPIKey:    envOr("ARCADE_WEBAPP_TGDB_APIKEY_FILE", ""),
	}
	for name, p := range map[string]string{
		"aria2-rpc":     secrets.Aria2RPC,
		"screenscraper": secrets.ScreenScraper,
		"tgdb-apikey":   secrets.TGDBAPIKey,
	} {
		if p == "" {
			log.Printf("arcade-webapp: secret %s: not configured", name)
			continue
		}
		if _, err := os.Stat(p); err != nil {
			// Presence check only — the file CONTENT is never read here.
			log.Printf("arcade-webapp: secret %s: %s not readable yet (%v)", name, p, err)
		} else {
			log.Printf("arcade-webapp: secret %s: file present at %s", name, p)
		}
	}

	cfg := scanner.Config{
		CatalogueTsv:       envOr("ARCADE_WEBAPP_CATALOGUE_TSV", ""),
		CartridgeRoot:      envOr("ARCADE_WEBAPP_CARTRIDGE_ROOT", ""),
		OpticalRoot:        envOr("ARCADE_WEBAPP_OPTICAL_ROOT", ""),
		ModernRoot:         envOr("ARCADE_WEBAPP_MODERN_ROOT", ""),
		DATDir:             envOr("ARCADE_WEBAPP_DAT_DIR", ""),
		SkyscraperCacheDir: envOr("ARCADE_WEBAPP_SKYSCRAPER_CACHE_DIR", ""),
		IncomingDir:        envOr("ARCADE_WEBAPP_INCOMING_DIR", ""),
		InventoryFile:      envOr("ARCADE_WEBAPP_INVENTORY_FILE", ""),
		ExoRoot:            envOr("ARCADE_WEBAPP_EXO_ROOT", ""),
		DBPath:             envOr("ARCADE_WEBAPP_DB", "/var/lib/arcade-webapp/arcade.db"),
	}

	if cfg.CatalogueTsv == "" {
		log.Fatal("arcade-webapp: ARCADE_WEBAPP_CATALOGUE_TSV is required (the module passes a store copy of scripts/cartridge-catalogue.tsv)")
	}

	// The ONE heavy-job lock shared by verify + scrape (ADV-P5-03): the
	// two runners each serialized only themselves, so a verify batch and
	// a scrape batch could overlap — both CPU/IO-heavy on the 2-core box,
	// both writing into the same games trees. Whoever grabs it second
	// gets that runner's usual ErrBusy (409), so HTTP behavior is
	// unchanged.
	heavy := &pipeline.Mutex{}

	st, err := store.Open(cfg.DBPath)
	if err != nil {
		log.Fatalf("arcade-webapp: open db %s: %v", cfg.DBPath, err)
	}
	defer st.Close() //nolint:errcheck // best effort at shutdown

	scan := scanner.New(cfg, st)

	// Download control (P2): the aria2 JSON-RPC client is wired only when
	// BOTH the RPC URL and the secret file are configured — otherwise the
	// downloads UI renders its static "not configured" state. The secret
	// is read from the file at CALL time by the client (never here, never
	// logged); the URL defaults to the fleet daemon on europa.
	var opts []web.Option
	rpcURL := envOr("ARCADE_WEBAPP_ARIA2_RPC_URL", "")
	if rpcURL != "" && secrets.Aria2RPC != "" {
		cl := aria2.New(rpcURL, secrets.Aria2RPC, log.Default())
		opts = append(opts, web.WithAria2(cl, cfg.IncomingDir, envOr("ARCADE_WEBAPP_TORRENT_DIR", "")))
		log.Printf("arcade-webapp: download control wired to %s (secret file at runtime)", rpcURL)
	} else {
		log.Printf("arcade-webapp: download control not configured (need ARCADE_WEBAPP_ARIA2_RPC_URL + ARCADE_WEBAPP_ARIA2_SECRET_FILE)")
	}

	// Verify + DAT manager (P3): the igir runner execs the binary the
	// module hands us (ARCADE_WEBAPP_IGIR_BIN — pkgs.igir from the
	// pinned nixpkgs), writing promoted ROMs into the bucket roots and
	// audit CSVs under <scratch>/reports. The DAT fetcher pulls the
	// Fresh1G1R McLean set on demand AND on a schedule (hours; 0/empty
	// disables — the VM test keeps it off for determinism).
	igirBin := envOr("ARCADE_WEBAPP_IGIR_BIN", "")
	scratchDir := envOr("ARCADE_WEBAPP_SCRATCH_DIR", "")
	var runner *igir.Runner
	if igirBin != "" {
		var nerr error
		runner, nerr = igir.New(igir.Config{
			Binary:        igirBin,
			IncomingDir:   cfg.IncomingDir,
			DATDir:        cfg.DATDir,
			CartridgeRoot: cfg.CartridgeRoot,
			OpticalRoot:   cfg.OpticalRoot,
			ModernRoot:    cfg.ModernRoot,
			ReportDir:     filepath.Join(scratchDir, "reports"),
		}, st, func() error {
			_, err := scan.Scan()
			return err
		}, log.Default())
		// ADV-P3-03: relative roots re-arm igir's cwd-rooted glob
		// expansion (the D-P3e hang) — fatal at startup, never a
		// minutes-long crawl in production. The module always passes
		// absolute paths; this catches hand-rolled envs.
		if nerr != nil {
			log.Fatalf("arcade-webapp: verify runner misconfigured: %v", nerr)
		}
		runner.Pipeline = heavy
		log.Printf("arcade-webapp: verify runner wired (igir %s, reports %s, shared pipeline slot)", igirBin, filepath.Join(scratchDir, "reports"))
	} else {
		log.Printf("arcade-webapp: verify not configured (ARCADE_WEBAPP_IGIR_BIN empty)")
	}
	var fetcher *dats.Fetcher
	if cfg.DATDir != "" {
		fetcher = &dats.Fetcher{
			BaseURL: envOr("ARCADE_WEBAPP_DAT_FETCH_BASE_URL", dats.DefaultBaseURL),
			Dir:     cfg.DATDir,
			St:      st,
			Log:     log.Default(),
		}
		log.Printf("arcade-webapp: DAT manager wired (%s -> %s)", fetcher.BaseURL, cfg.DATDir)
	}
	opts = append(opts, web.WithPipeline(runner, fetcher))

	// Game art (P4): the Skyscraper-cache media root — scraped
	// cover.png/jpg per game directory, served read-only. Unset = the
	// deterministic SVG posters only.
	if artDir := envOr("ARCADE_WEBAPP_ART_DIR", ""); artDir != "" {
		opts = append(opts, web.WithArt(artDir))
		log.Printf("arcade-webapp: game art wired (%s; SVG poster fallback)", artDir)
	} else {
		log.Printf("arcade-webapp: game art not configured (ARCADE_WEBAPP_ART_DIR empty) — SVG posters only")
	}
	// Skyscraper cache fallback for covers (PS1 1.5G demo: 790M covers
	// live under <cacheDir>/<sys>/covers/<source>/<id>.* — no extra
	// config). Wired unconditionally when the cache dir is known so
	// /art/<system>/<id> serves real covers without manual ARCADE_WEBAPP_ART_DIR.
	if cacheDir := envOr("ARCADE_WEBAPP_SKYSCRAPER_CACHE_DIR", ""); cacheDir != "" {
		opts = append(opts, web.WithCacheDir(cacheDir))
		log.Printf("arcade-webapp: cover cache fallback wired (%s)", cacheDir)
	}

	// Metadata engine (P5): the Skyscraper driver execs the binary the
	// module hands us (ARCADE_WEBAPP_SKYSCRAPER_BIN), writing into the
	// SAME resource cache the scanner reads for coverage
	// (ARCADE_WEBAPP_SKYSCRAPER_CACHE_DIR) and dropping Pegasus media next
	// to the games-tree ROMs. Credential FILES (the existing sops secret
	// paths, read at call time by the driver, never here, never logged)
	// enable the ScreenScraper primary pass and the TGDB apikey.
	var scraper *scrape.Driver
	skyBin := envOr("ARCADE_WEBAPP_SKYSCRAPER_BIN", "")
	if skyBin != "" && cfg.SkyscraperCacheDir != "" {
		scraper = &scrape.Driver{
			BinPath:                skyBin,
			CacheDir:               cfg.SkyscraperCacheDir,
			ScreenscraperCredsFile: secrets.ScreenScraper,
			TGDBKeyFile:            secrets.TGDBAPIKey,
			Store:                  st,
			Pipeline:               heavy,
			CartridgeRoot:          cfg.CartridgeRoot,
			OpticalRoot:            cfg.OpticalRoot,
			ModernRoot:             cfg.ModernRoot,
		}
		log.Printf("arcade-webapp: scrape driver wired (%s, cache %s, shared pipeline slot)", skyBin, cfg.SkyscraperCacheDir)
	} else {
		log.Printf("arcade-webapp: scrape not configured (need ARCADE_WEBAPP_SKYSCRAPER_BIN + ARCADE_WEBAPP_SKYSCRAPER_CACHE_DIR)")
	}
	opts = append(opts, web.WithScrape(scraper))

	// Launcher-DB generation (P6): the store is the source of truth and
	// the generator renders metadata.pegasus.txt per populated system dir
	// into the SAME bucket roots the scanner walks — atomically, strictly
	// self-validated, byte-stable. It shares the heavy-job lock so a
	// generation never overlaps a verify or scrape (ADV-P5-03 family);
	// triggers are the post-verify hook and the metadata page's manual
	// Regenerate button. No new configuration: the roots above are the
	// served trees.
	generator := &generate.Generator{
		St:            st,
		CartridgeRoot: cfg.CartridgeRoot,
		OpticalRoot:   cfg.OpticalRoot,
		ModernRoot:    cfg.ModernRoot,
		Pipeline:      heavy,
	}
	opts = append(opts, web.WithGenerator(generator))
	log.Printf("arcade-webapp: launcher-DB generator wired (%s, shared pipeline slot)",
		filepath.Join(cfg.CartridgeRoot, "<sys>", "metadata.pegasus.txt"))

	// Metadata schedule: every interval hours (default 24 — the old
	// jupiter-rom-scrape daily timer's cadence; 0 disables). Deliberately
	// NO startup run: scraping hits rate-limited community APIs with real
	// quota costs, so the first batch waits for the first tick or an
	// operator click. The driver serializes jobs itself, so a tick that
	// lands while a manual scrape runs is skipped (never stacked).
	if scraper != nil {
		hours := 24 // the old daily timer's default
		if v, err := strconv.Atoi(envOr("ARCADE_WEBAPP_SCRAPE_INTERVAL_HOURS", "")); err == nil {
			hours = v
		}
		switch {
		case hours > 0:
			go func() {
				t := time.NewTicker(time.Duration(hours) * time.Hour)
				defer t.Stop()
				for range t.C {
					err := scraper.StartAll()
					switch {
					case errors.Is(err, scrape.ErrBusy):
						log.Printf("arcade-webapp: scheduled scrape skipped (one already running)")
					case err != nil:
						log.Printf("arcade-webapp: scheduled scrape: %v", err)
					default:
						log.Printf("arcade-webapp: scheduled scrape kicked (%dh interval)", hours)
					}
				}
			}()
			log.Printf("arcade-webapp: scrape scheduled every %dh", hours)
		default:
			log.Printf("arcade-webapp: scrape schedule disabled (interval 0)")
		}
	}

	// DAT currency schedule: refresh at startup + every interval hours
	// (fetch-mclean-1g1r-dats.sh ran as a kicked oneshot; the webapp
	// owns the cadence now). Failures are per-system warnings in a
	// dat-fetch run — never fatal here.
	if fetcher != nil {
		if hours, err := strconv.Atoi(envOr("ARCADE_WEBAPP_DAT_REFRESH_HOURS", "")); err == nil && hours > 0 {
			f := fetcher
			go func() {
				ctx := context.Background()
				refresh := func() {
					systems, err := st.Systems()
					if err != nil {
						log.Printf("arcade-webapp: dat refresh: %v", err)
						return
					}
					res := f.Refresh(ctx, systems)
					log.Printf("arcade-webapp: dat refresh: %d fetched, %d unmapped, %d warnings",
						res.Fetched, res.Unmapped, len(res.Warnings))
				}
				refresh()
				t := time.NewTicker(time.Duration(hours) * time.Hour)
				defer t.Stop()
				for range t.C {
					refresh()
				}
			}()
			log.Printf("arcade-webapp: DAT refresh scheduled every %dh (+ at startup)", hours)
		}
	}

	srv, err := web.New(st, scan, opts...)
	if err != nil {
		log.Fatalf("arcade-webapp: %v", err)
	}

	// Startup scan in the background: the dashboard serves whatever the
	// last scan recorded while the fresh walk runs (R5: never block boot
	// on a full multi-TB tree walk).
	go func() {
		started := time.Now() // the duration IS the fix's proof (issue #81):
		// a warm boot must land in minutes, a cold backfill reports hours.
		res, err := scan.Scan()
		if err != nil {
			log.Printf("arcade-webapp: startup scan: %v", err)
			return
		}
		log.Printf("arcade-webapp: startup scan done in %s: %d systems, %d games (%s), %d warnings",
			time.Since(started).Round(time.Second), res.Systems, res.Games,
			web.HumanBytes(res.Bytes), len(res.Warnings))
	}()

	httpSrv := &http.Server{
		Addr:              addr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("arcade-webapp: listening on %s (db %s)", addr, filepath.Base(cfg.DBPath))
	if err := httpSrv.ListenAndServe(); err != nil {
		log.Fatalf("arcade-webapp: %v", err)
	}
}
