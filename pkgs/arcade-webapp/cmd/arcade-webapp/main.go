// arcade-webapp — entry point of the jupiterOS Arcade webapp (gauntlet
// plan Phase 1: pipeline dashboard).
//
// Configuration is env-driven; modules/services/arcade-webapp.nix owns the
// real options and maps them onto these. Path options are all runtime
// reads — secret material, when later phases need it, arrives as file
// PATHS (sops-decrypted at activation), never inline values.
package main

import (
	"log"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/scanner"
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
		DBPath:             envOr("ARCADE_WEBAPP_DB", "/var/lib/arcade-webapp/arcade.db"),
	}

	if cfg.CatalogueTsv == "" {
		log.Fatal("arcade-webapp: ARCADE_WEBAPP_CATALOGUE_TSV is required (the module passes a store copy of scripts/cartridge-catalogue.tsv)")
	}

	st, err := store.Open(cfg.DBPath)
	if err != nil {
		log.Fatalf("arcade-webapp: open db %s: %v", cfg.DBPath, err)
	}
	defer st.Close() //nolint:errcheck // best effort at shutdown

	scan := scanner.New(cfg, st)

	srv, err := web.New(st, scan)
	if err != nil {
		log.Fatalf("arcade-webapp: %v", err)
	}

	// Startup scan in the background: the dashboard serves whatever the
	// last scan recorded while the fresh walk runs (R5: never block boot
	// on a full multi-TB tree walk).
	go func() {
		res, err := scan.Scan()
		if err != nil {
			log.Printf("arcade-webapp: startup scan: %v", err)
			return
		}
		log.Printf("arcade-webapp: startup scan done: %d systems, %d games (%s), %d warnings",
			res.Systems, res.Games, web.HumanBytes(res.Bytes), len(res.Warnings))
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
