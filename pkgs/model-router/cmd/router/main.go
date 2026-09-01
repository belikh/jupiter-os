// Command router runs the model router service: a single binary exposing an
// OpenAI-compatible facade over pooled free inference endpoints, with a
// Zeus-styled dashboard, an encrypted credential vault, a learned quota
// ledger with reset scheduling, and a poll-based catalogue discovery loop.
package main

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"modelrouter/internal/config"
	"modelrouter/internal/db"
	"modelrouter/internal/discovery"
	"modelrouter/internal/facade"
	"modelrouter/internal/health"
	"modelrouter/internal/ledger"
	"modelrouter/internal/pool"
	"modelrouter/internal/seed"
	"modelrouter/internal/upstream"
	"modelrouter/internal/vault"
	"modelrouter/internal/web"
)

const shutdownTimeout = 15 * time.Second

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	sqlDB, err := db.Open(cfg.DBPath)
	if err != nil {
		log.Fatalf("db: %v", err)
	}

	// seed: the signed endpoint catalogue
	sd, err := seed.Load()
	if err != nil {
		log.Fatalf("seed: %v", err)
	}

	// vault: AES-256-GCM credential store
	masterKey, err := vault.MasterKeyFromEnvOrFile(cfg.DataDir)
	if err != nil {
		log.Fatalf("vault key: %v", err)
	}
	vlt, err := vault.Open(sqlDB, masterKey)
	if err != nil {
		log.Fatalf("vault: %v", err)
	}

	// core subsystems
	machine := health.NewMachine()
	machine.Tick(time.Now())
	led := ledger.New()
	pools := pool.New(machine, led, 0.5)

	// adapters: one generic OpenAI-compatible adapter per provider base URL
	adapters := make(map[string]upstream.Adapter)
	for _, p := range sd.Providers {
		if p.BaseURL == "" {
			continue
		}
		providerID := p.ID
		keyFn := func() string {
			if k, _, err := vlt.Get(providerID); err == nil {
				return k
			}
			return ""
		}
		adapters[providerID] = upstream.NewOpenAIAdapter(p.BaseURL, keyFn)
	}

	// configure ledger scopes from seed window hints
	for _, m := range sd.Models {
		if m.Status != "free" && m.Status != "free_capped" && m.Status != "trial" {
			continue
		}
		prov := providerByID(sd, m.ProviderID)
		if prov == nil {
			continue
		}
		kind := windowKindFor(prov)
		caps := capMapFor(prov)
		sc := health.Scope{Provider: m.ProviderID, Model: m.Family, Key: "default"}
		led.ConfigureScope(sc, kind, caps)
	}

	// the streaming walk
	walk := upstream.NewWalk(pools, led, machine, func(provider string) upstream.Adapter {
		return adapters[provider]
	})

	// discovery loop (nil event fn: the machine's ring feeds the UI)
	var discAdapters map[string]discovery.Adapter = make(map[string]discovery.Adapter)
	for id, ad := range adapters {
		discAdapters[id] = ad
	}
	loop := discovery.New(sd, pools, machine, discAdapters, nil)
	// seed the pools from the catalogue immediately
	disc2 := loop // alias for clarity
	_ = disc2
	// populate pools synchronously so the first request can route
	for _, m := range sd.Models {
		if m.Status != "free" && m.Status != "free_capped" && m.Status != "trial" {
			continue
		}
		if _, ok := adapters[m.ProviderID]; !ok {
			continue
		}
		pools.SetMembers(m.Family, append(pools.Members(m.Family), pool.Endpoint{
			Scope:   health.Scope{Provider: m.ProviderID, Model: m.Family, Key: "default"},
			Weights: map[string]float64{"rpm": 30},
			Family:  m.Family,
			LocalID: m.LocalSlug,
		}))
	}

	// facade: the OpenAI-compatible API
	famFn := func() []string {
		seen := make(map[string]bool)
		var out []string
		for _, m := range sd.Models {
			if (m.Status == "free" || m.Status == "free_capped" || m.Status == "trial") && !seen[m.Family] {
				seen[m.Family] = true
				out = append(out, m.Family)
			}
		}
		// live families from the pools too (discovery may have added)
		for _, m := range loop.Snapshot() {
			if !seen[m.Family] {
				seen[m.Family] = true
				out = append(out, m.Family)
			}
		}
		return out
	}
	api := facade.NewServer(cfg.ClientToken, walk, loop, famFn)

	// dashboard
	// Env bootstrap: providers with a seed env_key get their vault row
	// pre-seeded from the environment on first boot (no manual paste for
	// keys the host already holds). Existing rows are never overwritten —
	// the dashboard stays the source of truth once a key is stored.
	for _, p := range sd.Providers {
		if p.EnvKey == "" {
			continue
		}
		if _, ok := adapters[p.ID]; !ok {
			continue
		}
		if _, stored, err := vlt.Get(p.ID); err == nil && !stored {
			continue // nothing stored and no env key: onboarding page handles it
		} else if err == nil && stored {
			continue // already onboarded via the dashboard
		}
		envVal := os.Getenv(p.EnvKey)
		if envVal == "" {
			continue
		}
		if err := vlt.Put(p.ID, envVal); err != nil {
			log.Printf("env bootstrap: %s: vault put failed: %v", p.ID, err)
			continue
		}
		// validate with a models-list probe (same as the dashboard flow)
		if ad, ok := adapters[p.ID]; ok {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			if _, err := ad.ListModels(ctx); err != nil {
				_ = vlt.SetStatus(p.ID, vault.KeyStatus{State: vault.Invalid, Detail: "env bootstrap validation failed: " + err.Error()})
			} else {
				_ = vlt.SetStatus(p.ID, vault.KeyStatus{State: vault.Valid})
			}
			cancel()
		}
		log.Printf("env bootstrap: %s onboarded from %s", p.ID, p.EnvKey)
	}

	saveKey := func(providerID, key string) error {
		if err := vlt.Put(providerID, key); err != nil {
			return err
		}
		// validate with a cheap probe: list models with the new key
		if ad, ok := adapters[providerID]; ok {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			if _, err := ad.ListModels(ctx); err != nil {
				_ = vlt.SetStatus(providerID, vault.KeyStatus{State: vault.Invalid, Detail: "validation failed: " + err.Error()})
				return nil // stored but flagged invalid — the UI shows why
			}
			_ = vlt.SetStatus(providerID, vault.KeyStatus{State: vault.Valid})
		}
		return nil
	}
	dash := web.NewServer(pools, machine, led, sd, vlt, machine.Events, saveKey)

	// compose: one mux, two surfaces
	mux := http.NewServeMux()
	mux.Handle("/v1/", api.Mux())
	mux.Handle("/static/", dash.Mux())
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/v1") || strings.HasPrefix(r.URL.Path, "/static") || strings.HasPrefix(r.URL.Path, "/keys") || strings.HasPrefix(r.URL.Path, "/events") {
			dash.Mux().ServeHTTP(w, r)
			return
		}
		if r.URL.Path == "/healthz" {
			w.Write([]byte("ok"))
			return
		}
		dash.Mux().ServeHTTP(w, r) // dashboard at /
	})
	srv := &http.Server{Addr: cfg.ListenAddr, Handler: mux}

	// background loops: discovery polling + health clock
	bgCtx, bgStop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer bgStop()
	go loop.Run(bgCtx)
	go func() {
		t := time.NewTicker(10 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-bgCtx.Done():
				return
			case <-t.C:
				machine.Tick(time.Now())
			}
		}
	}()

	log.Printf("model router listening on %s (data dir %s, %d providers seeded, %d adapters)",
		cfg.ListenAddr, cfg.DataDir, len(sd.Providers), len(adapters))
	log.Printf("dashboard: http://%s/  ·  api: http://%s/v1  ·  token: set Authorization: Bearer <client token from %s>",
		cfg.ListenAddr, cfg.ListenAddr, cfg.DataDir+"/config.json")

	errCh := make(chan error, 1)
	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		sqlDB.Close()
		log.Fatalf("serve: %v", err)
	case <-bgCtx.Done():
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("shutdown: %v", err)
	}
	if err := sqlDB.Close(); err != nil {
		log.Printf("close db: %v", err)
	}
	log.Print("model router stopped")
}

func providerByID(sd seed.Seed, id string) *seed.Provider {
	for i := range sd.Providers {
		if sd.Providers[i].ID == id {
			return &sd.Providers[i]
		}
	}
	return nil
}

func windowKindFor(p *seed.Provider) ledger.WindowKind {
	if len(p.WindowHints) == 0 {
		return ledger.RollingHeaders
	}
	switch p.WindowHints[0].Kind {
	case "rolling_headers":
		return ledger.RollingHeaders
	case "fixed_pacific_midnight":
		return ledger.FixedPacificMidnight
	case "utc_midnight_shared":
		return ledger.UTCMidnightShared
	case "continuous_bucket":
		return ledger.ContinuousBucket
	case "session_5h_7d":
		return ledger.Session5h7d
	case "credit_expiry":
		return ledger.CreditExpiry
	}
	return ledger.RollingHeaders
}

func capMapFor(p *seed.Provider) map[string]float64 {
	out := make(map[string]float64)
	for _, c := range p.InitialCaps {
		switch c.Kind {
		case "rpm":
			out[ledger.DimRPM] = c.Value
		case "rpd":
			out[ledger.DimRPD] = c.Value
		case "tpm":
			out[ledger.DimTPM] = c.Value
		case "tpd":
			out[ledger.DimTPD] = c.Value
		case "neurons_day":
			out[ledger.DimNeuronsDay] = c.Value
		case "credits_month":
			out[ledger.DimCreditsMth] = c.Value
		case "concurrency":
			out[ledger.DimConcurrency] = c.Value
		case "rpd_unfunded":
			out[ledger.DimRPD] = c.Value // unfunded default until the $10 tier learns otherwise
		case "rpd_funded":
			// stored as a second cap the ledger can learn up to on credit
			out["rpd_funded"] = c.Value
		case "credit_threshold_usd":
			out["credit_threshold_usd"] = c.Value
		}
	}
	return out
}

var _ = sql.Open // keep the sql import for the signature docs
