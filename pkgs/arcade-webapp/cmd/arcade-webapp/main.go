// arcade-webapp — entry point of the jupiterOS Arcade webapp stub.
//
// Configuration is env-driven for now (Phase 1's NixOS module will own the
// real options; ARCADE_WEBAPP_ADDR maps to its future port option).
package main

import (
	"log"
	"net/http"
	"os"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/web"
)

func main() {
	addr := os.Getenv("ARCADE_WEBAPP_ADDR")
	if addr == "" {
		addr = ":8094"
	}

	srv := &http.Server{
		Addr:              addr,
		Handler:           web.New().Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("arcade-webapp: listening on %s", addr)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("arcade-webapp: %v", err)
	}
}
