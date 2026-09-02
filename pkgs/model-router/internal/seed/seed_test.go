package seed

import (
	"strings"
	"testing"
)

// TestLoadVerifiesAndParses is the core Task 2 contract: Load must verify the
// embedded signature before parsing and return a non-empty seed.
func TestLoadVerifiesAndParses(t *testing.T) {
	s, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(s.Providers) < 30 {
		t.Fatalf("providers = %d, want >= 30", len(s.Providers))
	}
	if len(s.Models) < 20 {
		t.Fatalf("model mappings = %d, want >= 20", len(s.Models))
	}
}

// TestProvidersHaveSignupAndKeyPages asserts every provider carries a signup
// URL and a key-page URL, plus a base URL and an API flavour.
func TestProvidersHaveSignupAndKeyPages(t *testing.T) {
	s, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range s.Providers {
		if !strings.HasPrefix(p.SignupURL, "https://") {
			t.Errorf("%s signup URL = %q, want https:// prefix", p.ID, p.SignupURL)
		}
		if !strings.HasPrefix(p.KeyPageURL, "https://") {
			t.Errorf("%s key page URL = %q, want https:// prefix", p.ID, p.KeyPageURL)
		}
		if !strings.HasPrefix(p.BaseURL, "https://") {
			t.Errorf("%s base URL = %q, want https:// prefix", p.ID, p.BaseURL)
		}
		if p.APIFlavour == "" {
			t.Errorf("%s has empty API flavour", p.ID)
		}
		if len(p.WindowHints) == 0 {
			t.Errorf("%s has no window hints", p.ID)
		}
		if p.Name == "" || p.ID == "" {
			t.Errorf("provider with empty ID or name: %+v", p)
		}
	}
}

// TestWindowHintKinds asserts every hint uses a known window kind.
func TestWindowHintKinds(t *testing.T) {
	s, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	known := map[string]bool{
		"rolling_headers":        true,
		"fixed_pacific_midnight": true,
		"utc_midnight_shared":    true,
		"continuous_bucket":      true,
		"session_5h_7d":          true,
		"credit_expiry":          true,
	}
	for _, p := range s.Providers {
		for _, h := range p.WindowHints {
			if !known[h.Kind] {
				t.Errorf("%s window hint kind %q is not a known kind", p.ID, h.Kind)
			}
			if h.Notes == "" {
				t.Errorf("%s window hint %q has no notes", p.ID, h.Kind)
			}
		}
	}
}

// TestModelMappingStatuses asserts every mapping row carries a known status
// and a family + provider pair.
func TestModelMappingStatuses(t *testing.T) {
	s, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	known := map[string]bool{
		"free": true, "free_capped": true, "trial": true,
		"paid": true, "paid_gated": true, "no_host": true,
	}
	for _, m := range s.Models {
		if !known[m.Status] {
			t.Errorf("model %s/%s has unknown status %q", m.Family, m.ProviderID, m.Status)
		}
		if m.Family == "" || m.ProviderID == "" {
			t.Errorf("model mapping with empty family or provider: %+v", m)
		}
	}
	// no_host rows are only informative when they carry notes.
	for _, m := range s.Models {
		if m.Status == "no_host" && m.Notes == "" {
			t.Errorf("no_host row %s/%s has no notes — uninformative", m.Family, m.ProviderID)
		}
	}
}

// TestSeedResearchContent spot-checks the compiled research data: caps and
// window kinds for a few load-bearing providers.
func TestSeedResearchContent(t *testing.T) {
	s, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	byID := map[string]Provider{}
	for _, p := range s.Providers {
		byID[p.ID] = p
	}

	checks := []struct {
		id           string
		windowKind   string
		wantCapKey   string
		wantCapValue float64
	}{
		{"openrouter", "utc_midnight_shared", "rpm", 20},
		{"google", "fixed_pacific_midnight", "rpd", 1500},
		{"groq", "rolling_headers", "tpd", 200000},
		{"nvidia", "rolling_headers", "rpm", 40},
		{"cloudflare", "utc_midnight_shared", "neurons_day", 10000},
		{"zai", "session_5h_7d", "concurrency", 1},
		{"ollama", "session_5h_7d", "concurrency", 1},
		{"huggingface", "credit_expiry", "credits_month", 0.10},
		{"cerebras", "continuous_bucket", "tpd", 1000000},
		{"ovh", "rolling_headers", "rpm", 2},
	}
	for _, c := range checks {
		p, ok := byID[c.id]
		if !ok {
			t.Errorf("provider %s missing from seed", c.id)
			continue
		}
		found := false
		for _, h := range p.WindowHints {
			if h.Kind == c.windowKind {
				found = true
			}
		}
		if !found {
			t.Errorf("%s: no %q window hint", c.id, c.windowKind)
		}
		cap, ok := p.InitialCaps[c.wantCapKey]
		if !ok {
			t.Errorf("%s: missing cap %q", c.id, c.wantCapKey)
			continue
		}
		if cap.Kind != c.wantCapKey {
			t.Errorf("%s: cap %q has kind %q", c.id, c.wantCapKey, cap.Kind)
		}
		if cap.Value != c.wantCapValue {
			t.Errorf("%s: cap %q = %v, want %v", c.id, c.wantCapKey, cap.Value, c.wantCapValue)
		}
	}

	// Friction flags from the research matrix.
	if len(byID["cerebras"].FrictionFlags) == 0 {
		t.Error("cerebras missing friction flags (card required, trial expiry)")
	}
	if len(byID["modelscope"].FrictionFlags) == 0 {
		t.Error("modelscope missing friction flags (real-name verification)")
	}
	if len(byID["siliconflow"].FrictionFlags) == 0 {
		t.Error("siliconflow missing friction flags (real-name gate)")
	}
}

// TestTamperedSeedRejected is the security contract: a modified seed body
// must fail Ed25519 verification, not silently parse. Load() already proves
// the genuine embedded copy passes; here the verification path is probed
// directly with bodies that were never signed.
func TestTamperedSeedRejected(t *testing.T) {
	if _, err := Load(); err != nil {
		t.Fatalf("Load on the genuine seed: %v", err)
	}

	if err := verifySeed([]byte(`{"providers":[],"models":[]}`)); err == nil {
		t.Fatal("verifySeed accepted a body that was never signed")
	}

	// Flip a byte inside the real embedded seed: signature check must fail.
	tampered := append([]byte(nil), seedJSON...)
	if len(tampered) < 100 {
		t.Fatalf("embedded seed suspiciously short: %d bytes", len(tampered))
	}
	if tampered[50] == '{' {
		tampered[50] = '}'
	} else {
		tampered[50] = '{'
	}
	if err := verifySeed(tampered); err == nil {
		t.Fatal("verifySeed accepted a tampered seed body")
	}
}

// TestLoadCarriesEnvKeys asserts the providerJSON -> Provider conversion
// keeps EnvKey: the env-bootstrap path in the router silently no-ops when
// this field is dropped (observed live on callisto — zero vault rows
// despite keys present in the service environment).
func TestLoadCarriesEnvKeys(t *testing.T) {
	sd, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	var withEnv []string
	for _, p := range sd.Providers {
		if p.EnvKey != "" {
			withEnv = append(withEnv, p.ID+"->"+p.EnvKey)
		}
	}
	if len(withEnv) == 0 {
		t.Fatal("no providers carry env_key after Load — the wire conversion dropped the field")
	}
	t.Logf("env-keyed providers: %v", withEnv)
}
