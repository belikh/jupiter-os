package main

import (
	"bufio"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// TestParseFixture streams a real internal-json log captured from europa's
// jupiter-ci (CI run 31295971155, a callisto build that substituted its
// whole closure — no local builds) and checks the resulting state is sane.
func TestParseFixture(t *testing.T) {
	f, err := os.Open("testdata/sample-small.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	s := newState()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 1<<20)
	var lines int
	for sc.Scan() {
		line := sc.Text()
		rest, ok := strings.CutPrefix(line, "@nix ")
		if !ok {
			continue
		}
		var ev rawEvent
		if err := json.Unmarshal([]byte(rest), &ev); err != nil {
			t.Fatalf("failed to parse line %d (%q): %v", lines, line, err)
		}
		s.apply(&ev)
		lines++
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	if lines == 0 {
		t.Fatal("fixture produced no events")
	}

	// All start/stop pairs in this fixture are balanced, so no activity
	// should be left dangling once the whole file is consumed.
	if len(s.activities) != 0 {
		t.Errorf("expected all activities to be stopped, %d still open", len(s.activities))
	}
	if lines != 144 {
		t.Errorf("expected 144 events in the fixture, got %d", lines)
	}

	if s.title == "" {
		t.Error("expected the '=== jupiter-ci ... ===' header to set a title")
	}
	const wantTitle = "jupiter-ci 31295971155: building callisto"
	if s.title != wantTitle {
		t.Errorf("title = %q, want %q", s.title, wantTitle)
	}
}

// TestAggregateLiveProgress exercises the case the fixture above can't: an
// activity that is still running (not yet stopped) when a snapshot is
// taken. nix's own renderActivity sums live activities into the aggregate,
// not just ones that have already stopped — this pins that behavior.
func TestAggregateLiveProgress(t *testing.T) {
	s := newState()
	s.apply(&rawEvent{Action: "start", ID: 1, Type: int(actBuild), Fields: []interface{}{
		"/nix/store/j3wl46dgzlyr8bhqh0k24any86x0wn1j-hello-2.12.drv", "",
	}})
	s.apply(&rawEvent{Action: "result", ID: 1, Type: int(resProgress), Fields: []interface{}{
		float64(3), float64(10), float64(1), float64(0),
	}})

	done, expected, running, failed := s.aggregate(actBuild)
	if done != 3 || expected != 10 || running != 1 || failed != 0 {
		t.Errorf("aggregate(actBuild) while running = (%d,%d,%d,%d), want (3,10,1,0)", done, expected, running, failed)
	}

	s.apply(&rawEvent{Action: "stop", ID: 1})
	done, expected, running, failed = s.aggregate(actBuild)
	if done != 3 || running != 0 || failed != 0 {
		t.Errorf("aggregate(actBuild) after stop = (%d,%d,%d,%d), want done/failed preserved, running 0", done, expected, running, failed)
	}
}

func TestStorePathToName(t *testing.T) {
	cases := map[string]string{
		"/nix/store/j3wl46dgzlyr8bhqh0k24any86x0wn1j-source":                "source",
		"/nix/store/bj4wgswrnygnz55hwh6xd1ci8wal56lk-unit-orca.service.drv": "unit-orca.service.drv",
	}
	for in, want := range cases {
		if got := storePathToName(in); got != want {
			t.Errorf("storePathToName(%q) = %q, want %q", in, got, want)
		}
	}
	if got := storePathToNameWithoutDrvSuffix("/nix/store/bj4wgswrnygnz55hwh6xd1ci8wal56lk-unit-orca.service.drv"); got != "unit-orca.service" {
		t.Errorf("storePathToNameWithoutDrvSuffix = %q", got)
	}
}
