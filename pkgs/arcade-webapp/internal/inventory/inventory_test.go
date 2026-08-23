package inventory

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// legacyFixture loads the committed document in the EXACT shape the
// retired jupiter-arcade-inventory jq pipeline emitted (same key order is
// irrelevant; same keys, types and value shapes are the contract).
func legacyFixture(t *testing.T) map[string]any {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "..", "testdata", "inventory-legacy.json"))
	if err != nil {
		t.Fatalf("legacy fixture missing: %v", err)
	}
	var doc map[string]any
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatalf("fixture unparseable: %v", err)
	}
	return doc
}

// oursFromEquivalentInputs builds our Doc from store aggregates carrying
// the SAME numbers as the fixture.
func oursFromEquivalentInputs(t *testing.T) Doc {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "inv.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() }) //nolint:errcheck // test

	rows := []store.SystemRow{
		{Key: "nes", Collection: "NES", Bucket: "cartridge", SortOrder: 1},
		{Key: "snes", Collection: "SNES", Bucket: "cartridge", SortOrder: 2},
		{Key: "gb", Collection: "GB", Bucket: "cartridge", SortOrder: 3},
		{Key: "segacd", Collection: "Sega CD", Bucket: "optical", SortOrder: 4},
	}
	if err := st.UpsertSystems(rows); err != nil {
		t.Fatal(err)
	}
	seed := map[string][]store.GameRow{
		"nes":    games(5, 12288),
		"snes":   games(4, 13312),
		"gb":     games(4, 10240),
		"segacd": games(1, 6272),
	}
	for sys, gs := range seed {
		if err := st.ReplaceSystemGames(sys, gs, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	summary, err := st.SystemSummary()
	if err != nil {
		t.Fatal(err)
	}
	exo := map[string]store.ExoStat{
		"dos":   {Games: 6, Art: 5},
		"win3x": {},
		"win9x": {},
	}
	return Build(summary, exo, "inactive", time.Date(2026, 8, 23, 9, 0, 0, 0, time.UTC))
}

// games builds n game rows of size each (plus one companion byte on the
// first row so sizes can hit odd totals).
func games(n int64, size int64) []store.GameRow {
	out := make([]store.GameRow, 0, n)
	for i := int64(0); i < n; i++ {
		out = append(out, store.GameRow{RelPath: fmt.Sprintf("Game %02d.rom", i), SizeBytes: size})
	}
	return out
}

// TestLegacyShapeParity walks both documents recursively and requires,
// at every level: identical key sets, identical JSON types, and equal
// values — except generated_at, compared by FORMAT (it is a timestamp).
// This pins P8's subsumption contract: make status-arcade keeps working
// against the webapp endpoint unchanged.
func TestLegacyShapeParity(t *testing.T) {
	legacy := legacyFixture(t)
	oursAny, err := json.Marshal(oursFromEquivalentInputs(t))
	if err != nil {
		t.Fatal(err)
	}
	var ours map[string]any
	if err := json.Unmarshal(oursAny, &ours); err != nil {
		t.Fatal(err)
	}

	compare(t, "$", legacy, ours)
}

func compare(t *testing.T, path string, want, got any) {
	t.Helper()
	wv, gv := reflect.ValueOf(want), reflect.ValueOf(got)
	if wv.Kind() != gv.Kind() {
		t.Fatalf("%s: type mismatch: legacy %T vs ours %T (%v vs %v)", path, want, got, want, got)
	}
	switch wv.Kind() {
	case reflect.Map:
		wkeys, gkeys := mapKeys(want), mapKeys(got)
		if !reflect.DeepEqual(wkeys, gkeys) {
			t.Fatalf("%s: key sets differ:\n legacy-only: %v\n ours-only: %v", path, missing(wkeys, gkeys), missing(gkeys, wkeys))
		}
		for _, k := range wkeys {
			compare(t, path+"."+k, want.(map[string]any)[k], got.(map[string]any)[k])
		}
	case reflect.String:
		ws, gs := want.(string), got.(string)
		if strings.HasSuffix(path, ".generated_at") {
			assertTimestamp(t, path, gs)
			return
		}
		if ws != gs {
			t.Fatalf("%s: %q != %q", path, ws, gs)
		}
	default:
		if want != got {
			t.Fatalf("%s: %v != %v (%T)", path, want, got, got)
		}
	}
}

func mapKeys(m any) []string {
	out := make([]string, 0, len(m.(map[string]any)))
	for k := range m.(map[string]any) {
		out = append(out, k)
	}
	// deterministic for stable failure messages
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j] < out[j-1]; j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out
}

func missing(want, got []string) []string {
	set := map[string]bool{}
	for _, k := range got {
		set[k] = true
	}
	var out []string
	for _, k := range want {
		if !set[k] {
			out = append(out, k)
		}
	}
	return out
}

func assertTimestamp(t *testing.T, path, v string) {
	t.Helper()
	if len(v) != 20 || v[4] != '-' || v[10] != 'T' || v[19] != 'Z' {
		t.Fatalf("%s: generated_at %q is not date -u %%Y-%%m-%%dT%%H:%%M:%%SZ shape", path, v)
	}
}

// TestCoveragePctFormula pins the exact jq arithmetic including the
// zero-games guard (never NaN).
func TestCoveragePctFormula(t *testing.T) {
	cases := []struct {
		art, games int64
		want       float64
	}{
		{5, 6, 83.3}, // floor(83.333…*1000... wait: floor(5/6*1000)/10 = floor(833.33)/10 = 83.3
		{1, 3, 33.3},
		{0, 7, 0},
		{0, 0, 0},
		{7, 7, 100},
	}
	for _, c := range cases {
		if got := CoveragePct(c.art, c.games); got != c.want {
			t.Errorf("CoveragePct(%d,%d) = %v, want %v", c.art, c.games, got, c.want)
		}
	}
}
