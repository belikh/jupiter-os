package seed_test

import (
	"testing"

	"modelrouter/internal/seed"
)

// TestEnvKeysCarryThrough guards the wire→domain mapping: providers with an
// env_key in seed.json must surface EnvKey on the decoded Provider. This
// exact field was once dropped in the providerJSON→Provider conversion,
// which silently disabled first-boot env bootstrap on the fleet host.
func TestEnvKeysCarryThrough(t *testing.T) {
	sd, err := seed.Load()
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"groq":        "GROQ_API_KEY",
		"zai":         "Z_AI_API_KEY",
		"opencode":    "OPENCODE_API_KEY",
		"tokenrouter": "TOKENROUTER_API_KEY",
	}
	got := 0
	for _, p := range sd.Providers {
		if want, ok := want[p.ID]; ok {
			if p.EnvKey != want {
				t.Errorf("%s EnvKey = %q, want %q", p.ID, p.EnvKey, want)
			}
			got++
		}
	}
	if got != len(want) {
		t.Fatalf("env-key providers found %d of %d — the wire mapping dropped EnvKey again", got, len(want))
	}
}
