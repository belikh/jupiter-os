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
		// Alias-aware key resolution: empty alias means "any usable
		// key" (used by ListModels probes); a concrete alias resolves
		// exactly that row.
		keyFn := func(alias string) string {
			ids := []string{alias}
			if alias == "" {
				var err error
				ids, err = vlt.ActiveAliases(providerID)
				if err != nil || len(ids) == 0 {
					ids = []string{"default"} // vault empty: send no key
				}
			}
			for _, id := range ids {
				if k, ok, err := vlt.Get(providerID, id); err == nil && ok && k != "" {
					return k
				}
			}
			return ""
		}
		adapters[providerID] = upstream.NewOpenAIAdapter(p.BaseURL, keyFn)
	}

	// Env bootstrap: providers with a seed env_key get their vault row
	// pre-seeded from the environment on first boot (no manual paste for
	// keys the host already holds). The row lands under the "env" alias;
	// existing rows are never overwritten — the dashboard stays the
	// source of truth once a key is stored.
	for _, p := range sd.Providers {
		if p.EnvKey == "" {
			continue
		}
		if _, ok := adapters[p.ID]; !ok {
			continue
		}
		if _, ok, err := vlt.Get(p.ID, "env"); err == nil && ok {
			continue // already bootstrapped from the environment
		}
		envVal := os.Getenv(p.EnvKey)
		if envVal == "" {
			continue
		}
		if err := vlt.Put(p.ID, "env", envVal); err != nil {
			log.Printf("env bootstrap: %s: vault put failed: %v", p.ID, err)
			continue
		}
		// validate with a models-list probe (same as the dashboard flow)
		if ad, ok := adapters[p.ID]; ok {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			if _, err := ad.ListModels(ctx); err != nil {
				_ = vlt.SetStatus(p.ID, "env", vault.KeyStatus{State: vault.Invalid, Detail: "env bootstrap validation failed: " + err.Error()})
			} else {
				_ = vlt.SetStatus(p.ID, "env", vault.KeyStatus{State: vault.Valid})
			}
			cancel()
		}
		log.Printf("env bootstrap: %s onboarded from %s", p.ID, p.EnvKey)
	}

	// syncProviderKeys rebuilds one provider's pool endpoints across all
	// its active key aliases — sibling keys spread load like any other
	// endpoint dimension (a 429 on one key no longer exhausts the
	// provider's whole quota). The provider's previous endpoints are
	// replaced, never appended (fresh saves must not duplicate rows).
	syncProviderKeys := func(providerID string) {
		aliases, err := vlt.ActiveAliases(providerID)
		if err != nil || len(aliases) == 0 {
			aliases = []string{"default"}
		}
		for _, m := range sd.Models {
			if m.ProviderID != providerID {
				continue
			}
			if m.Status != "free" && m.Status != "free_capped" && m.Status != "trial" {
				continue
			}
			if _, ok := adapters[m.ProviderID]; !ok {
				continue
			}
			eps := make([]pool.Endpoint, 0, len(aliases))
			for _, alias := range aliases {
				eps = append(eps, pool.Endpoint{
					Scope:   health.Scope{Provider: m.ProviderID, Model: m.Family, Key: alias},
					Weights: map[string]float64{"rpm": 30},
					Family:  m.Family,
					LocalID: m.LocalSlug,
				})
			}
			// replace semantics: drop this provider's old endpoints in
			// the family, keep every other provider's
			merged := []pool.Endpoint{}
			for _, e := range pools.Members(m.Family) {
				if e.Scope.Provider != providerID {
					merged = append(merged, e)
				}
			}
			pools.SetMembers(m.Family, append(merged, eps...))
		}
	}

	// seed the pools across active aliases so the first request can route
	seeded := make(map[string]bool)
	for _, m := range sd.Models {
		if m.Status != "free" && m.Status != "free_capped" && m.Status != "trial" {
			continue
		}
		if _, ok := adapters[m.ProviderID]; !ok {
			continue
		}
		if !seeded[m.ProviderID] {
			seeded[m.ProviderID] = true
			syncProviderKeys(m.ProviderID)
		}
	}

	// configure ledger scopes from seed window hints (one scope per
	// provider×family×alias — aliases share the provider's windows)
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
		aliases, err := vlt.ActiveAliases(m.ProviderID)
		if err != nil || len(aliases) == 0 {
			aliases = []string{"default"}
		}
		for _, alias := range aliases {
			sc := health.Scope{Provider: m.ProviderID, Model: m.Family, Key: alias}
			led.ConfigureScope(sc, kind, caps)
		}
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
	aliasesFor := func(providerID string) []string {
		if ids, err := vlt.ActiveAliases(providerID); err == nil && len(ids) > 0 {
			return ids
		}
		return nil
	}
	loop := discovery.New(sd, pools, machine, discAdapters, nil, aliasesFor)
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

	saveKey := func(providerID, alias, key string) error {
		if err := vlt.Put(providerID, alias, key); err != nil {
			return err
		}
		// validate with a cheap probe: list models with the new key
		if ad, ok := adapters[providerID]; ok {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			if _, err := ad.ListModels(ctx); err != nil {
				_ = vlt.SetStatus(providerID, alias, vault.KeyStatus{State: vault.Invalid, Detail: "validation failed: " + err.Error()})
			} else {
				_ = vlt.SetStatus(providerID, alias, vault.KeyStatus{State: vault.Valid})
			}
		}
		// refresh the pools: the new alias takes traffic immediately
		syncProviderKeys(providerID)
		return nil
	}
	deleteKey := func(providerID, alias string) error {
		if err := vlt.DeleteKey(providerID, alias); err != nil {
			return err
		}
		// refresh the pools: the alias's endpoints leave rotation
		syncProviderKeys(providerID)
		return nil
	}
	dash := web.NewServer(pools, machine, led, sd, vlt, machine.Events, saveKey, deleteKey)

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
