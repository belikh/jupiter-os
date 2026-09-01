// Package seed loads the bundled provider/model metadata compiled from the
// research corpus. The embedded seed.json is signed with Ed25519; Load
// verifies the signature before parsing so a tampered or substituted seed is
// rejected rather than silently consumed.
package seed

import (
	"crypto/ed25519"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
)

// seedJSON is the signed seed body. Its exact bytes are covered by seedSig.
//
//go:embed seed.json
var seedJSON []byte

// seedSig is the raw 64-byte Ed25519 signature over the exact bytes of
// seed.json, produced by the in-task generator (see the Task 2 report).
//
//go:embed seed.json.sig
var seedSig []byte

// seedPubHex is the Ed25519 public key (hex) whose private counterpart signed
// seed.json. Only the public key is committed; the private key was discarded
// after generation and exists nowhere in the repository.
const seedPubHex = "9e380ce4d691c347a36bedc1b84d1b9d44ee6296a9e057dc7ec385cfb444ca5e"

// Window kinds understood by the router's rate-window machinery.
const (
	WindowRollingHeaders       = "rolling_headers"        // x-ratelimit-* headers count down a rolling window
	WindowFixedPacificMidnight = "fixed_pacific_midnight" // fixed window resetting at Pacific midnight
	WindowUTCMidnightShared    = "utc_midnight_shared"    // shared account budget resetting 00:00 UTC
	WindowContinuousBucket     = "continuous_bucket"      // continuous token/credit bucket
	WindowSession5h7d          = "session_5h_7d"          // 5-hour rolling session within a 7-day cap
	WindowCreditExpiry         = "credit_expiry"          // credits expire on a calendar schedule
)

// Model mapping statuses.
const (
	StatusFree       = "free"
	StatusFreeCapped = "free_capped"
	StatusTrial      = "trial"
	StatusPaid       = "paid"
	StatusPaidGated  = "paid_gated"
	StatusNoHost     = "no_host"
)

// WindowHint describes one rate-limit window a provider enforces. Kind is one
// of the Window* constants; Notes carries the research-derived operational
// guidance for that window.
type WindowHint struct {
	Kind  string `json:"kind"`
	Notes string `json:"notes"`
}

// Cap is one named numeric quota a provider starts a window with. Kind names
// the quota (rpm, rpd, tpm, tpd, neurons_day, concurrency, credits_month,
// rpd_unfunded, rpd_funded, credit_threshold_usd, ...).
type Cap struct {
	Kind  string  `json:"kind"`
	Value float64 `json:"value"`
}

// capJSON is the wire shape of InitialCaps in seed.json: a flat map from
// quota name to number, decoded into Cap with Kind mirroring the key.
type capJSON map[string]float64

// Provider is one inference endpoint from the research corpus: where to sign
// up, where to create a key, where requests go, and what limits apply.
type Provider struct {
	ID            string         `json:"id"`
	Name          string         `json:"name"`
	SignupURL     string         `json:"signup_url"`
	KeyPageURL    string         `json:"key_page_url"`
	BaseURL       string         `json:"base_url"`
	APIFlavour    string         `json:"api_flavour"`
	WindowHints   []WindowHint   `json:"window_hints"`
	InitialCaps   map[string]Cap `json:"-"`
	FrictionFlags []string       `json:"friction_flags"`
	EnvKey        string         `json:"env_key,omitempty"`
}

// providerJSON is the wire shape of a provider row; InitialCaps arrives as a
// flat name→number map and is re-keyed into Cap values.
type providerJSON struct {
	ID            string       `json:"id"`
	Name          string       `json:"name"`
	SignupURL     string       `json:"signup_url"`
	KeyPageURL    string       `json:"key_page_url"`
	BaseURL       string       `json:"base_url"`
	APIFlavour    string       `json:"api_flavour"`
	WindowHints   []WindowHint `json:"window_hints"`
	InitialCaps   capJSON      `json:"initial_caps"`
	FrictionFlags []string     `json:"friction_flags"`
	EnvKey        string       `json:"env_key,omitempty"`
}

// ModelMapping maps a frontier model family to one provider's local slug and
// the access status the research established for it.
type ModelMapping struct {
	Family     string `json:"family"`
	ProviderID string `json:"provider_id"`
	LocalSlug  string `json:"local_slug"`
	Status     string `json:"status"`
	Notes      string `json:"notes"`
}

// Seed is the fully decoded, signature-verified seed document.
type Seed struct {
	Providers []Provider     `json:"providers"`
	Models    []ModelMapping `json:"models"`
}

// seedDoc is the wire shape of seed.json.
type seedDoc struct {
	Providers []providerJSON `json:"providers"`
	Models    []ModelMapping `json:"models"`
}

// verifySeed checks the Ed25519 signature over body. It returns an error for
// any body that was not signed by the embedded public key.
func verifySeed(body []byte) error {
	pub, err := hex.DecodeString(seedPubHex)
	if err != nil {
		return fmt.Errorf("decode seed public key: %w", err)
	}
	if len(pub) != ed25519.PublicKeySize {
		return fmt.Errorf("seed public key is %d bytes, want %d", len(pub), ed25519.PublicKeySize)
	}
	if len(seedSig) != ed25519.SignatureSize {
		return fmt.Errorf("embedded signature is %d bytes, want %d", len(seedSig), ed25519.SignatureSize)
	}
	if !ed25519.Verify(ed25519.PublicKey(pub), body, seedSig) {
		return fmt.Errorf("seed signature verification failed: seed body does not match the trusted signature")
	}
	return nil
}

// Load verifies and parses the embedded seed. Any tampering with the seed
// body — or a signature/public-key mismatch — is an error; callers never see
// unverified data.
func Load() (Seed, error) {
	var s Seed
	if err := verifySeed(seedJSON); err != nil {
		return s, err
	}
	var doc seedDoc
	if err := json.Unmarshal(seedJSON, &doc); err != nil {
		return s, fmt.Errorf("parse seed.json: %w", err)
	}
	s.Providers = make([]Provider, 0, len(doc.Providers))
	for _, p := range doc.Providers {
		prov := Provider{
			ID:            p.ID,
			Name:          p.Name,
			SignupURL:     p.SignupURL,
			KeyPageURL:    p.KeyPageURL,
			BaseURL:       p.BaseURL,
			APIFlavour:    p.APIFlavour,
			WindowHints:   p.WindowHints,
			InitialCaps:   make(map[string]Cap, len(p.InitialCaps)),
			FrictionFlags: p.FrictionFlags,
		}
		for kind, value := range p.InitialCaps {
			prov.InitialCaps[kind] = Cap{Kind: kind, Value: value}
		}
		s.Providers = append(s.Providers, prov)
	}
	s.Models = doc.Models
	return s, nil
}
