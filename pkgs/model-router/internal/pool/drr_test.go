package pool

import (
	"testing"

	"modelrouter/internal/health"
)

// The Dynamo reproduction: 512:128 quantum ratio drives ~4:1 completion
// share under a pure DRR scheduler (no P2C/Thompson interference).
func TestDRRPureCapShareWeights(t *testing.T) {
	d := NewDRR()
	big := ep("big", "m", 512)
	small := ep("small", "m", 128)
	eligible := []Endpoint{big, small}
	d.Configure("m", eligible)

	counts := map[string]int{}
	for i := 0; i < 320; i++ {
		got, ok := d.Next("m", eligible)
		if !ok {
			t.Fatal("Next failed")
		}
		counts[got.Scope.Provider]++
	}
	ratio := float64(counts["big"]) / float64(counts["small"])
	if ratio < 2.5 || ratio > 5.5 {
		t.Fatalf("pure DRR completion ratio = %.1f, want ~4:1 (got %v)", ratio, counts)
	}
}

func TestDRRSingleEndpoint(t *testing.T) {
	d := NewDRR()
	only := ep("solo", "m", 10)
	d.Configure("m", []Endpoint{only})
	for i := 0; i < 5; i++ {
		got, ok := d.Next("m", []Endpoint{only})
		if !ok || got.Scope.Provider != "solo" {
			t.Fatalf("solo Next = %v %v", got, ok)
		}
	}
	if _, ok := d.Next("m", nil); ok {
		t.Fatal("empty eligible must fail")
	}
	_ = health.Scope{} // keep import honest
}
