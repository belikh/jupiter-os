package main

import (
	"encoding/base64"
	"sort"
	"time"
)

// Snapshot is the JSON payload pushed to the browser over SSE. It is a
// point-in-time rendering of state, not the raw event stream — clients
// (including late subscribers to a session already in progress) always get
// the current picture, never a frame-by-frame replay.
type Snapshot struct {
	Title     string        `json:"title"`
	ElapsedMS int64         `json:"elapsedMs"`
	Finished  bool          `json:"finished"`
	Events    uint64        `json:"events"`
	Summary   []SummaryItem `json:"summary"`
	Active    []ActiveItem  `json:"active"`
	Recent    []string      `json:"recent"`
	Warnings  []string      `json:"warnings"`
	Corrupted uint64        `json:"corrupted"`
	Untrusted uint64        `json:"untrusted"`

	// Dependency tree state. The forest itself is fetched once from
	// /api/logs/{name}/tree — only DrvStates rides the stream, one base64'd
	// byte per node, so a 1000-derivation tree costs ~1.5 KB per snapshot
	// instead of being re-serialised at the broadcast rate. TreeSize tells
	// the client when the forest grew and must be re-fetched.
	TreeSize  int    `json:"treeSize"`
	DrvStates string `json:"drvStates"`
}

type SummaryItem struct {
	Label    string `json:"label"`
	Done     uint64 `json:"done"`
	Expected uint64 `json:"expected"`
	Running  uint64 `json:"running"`
	Failed   uint64 `json:"failed"`
	Bytes    bool   `json:"bytes"`
}

type ActiveItem struct {
	Kind      string `json:"kind"`
	Name      string `json:"name"`
	Machine   string `json:"machine"`
	Phase     string `json:"phase"`
	LastLine  string `json:"lastLine"`
	Done      uint64 `json:"done"`
	Expected  uint64 `json:"expected"`
	ElapsedMS int64  `json:"elapsedMs"`
}

var kindNames = map[ActivityType]string{
	actBuild:         "build",
	actSubstitute:    "fetch",
	actPostBuildHook: "post-build",
	actQueryPathInfo: "query",
	actCopyPath:      "copy",
	actFileTransfer:  "download",
}

// aggregate sums a type's counters the way nix's own renderActivity does:
// the accumulated done/failed from activities that have already stopped,
// PLUS the live done/expected/running/failed of every still-active activity
// of that type (which includes, for container types like actBuilds, the
// container activity's own counters — nix reports "N expected" via a
// resProgress/resSetExpected on the container itself, not the child). Must
// be called with s.mu held.
func (s *state) aggregate(t ActivityType) (done, expected, running, failed uint64) {
	agg := s.byType[t]
	if agg == nil {
		return 0, 0, 0, 0
	}
	done, failed = agg.done, agg.failed
	expected = done
	for id := range agg.active {
		a, ok := s.activities[id]
		if !ok {
			continue
		}
		done += a.done
		expected += a.expected
		running += a.running
		failed += a.failed
	}
	if agg.expected > expected {
		expected = agg.expected
	}
	return
}

func (s *state) summaryItem(label string, t ActivityType, bytes bool) SummaryItem {
	done, expected, running, failed := s.aggregate(t)
	return SummaryItem{Label: label, Done: done, Expected: expected, Running: running, Failed: failed, Bytes: bytes}
}

// snapshot renders the current state. Must be called with s.mu held.
func (s *state) snapshot(finished bool) Snapshot {
	snap := Snapshot{
		Title:     s.title,
		ElapsedMS: time.Since(s.startTime).Milliseconds(),
		Finished:  finished,
		Events:    s.events,
		Recent:    s.recentLines.items(),
		Warnings:  s.warnings.items(),
		Corrupted: s.corruptedPaths,
		Untrusted: s.untrustedPaths,
		TreeSize:  len(s.drvs),
		DrvStates: s.encodeDrvStates(),
	}

	snap.Summary = []SummaryItem{
		s.summaryItem("built", actBuilds, false),
		s.summaryItem("copied", actCopyPaths, false),
		s.summaryItem("downloaded", actFileTransfer, true),
		s.summaryItem("optimised", actOptimiseStore, false),
		s.summaryItem("verified", actVerifyPaths, false),
	}

	now := time.Now()
	for _, a := range s.activities {
		kind, ok := kindNames[a.typ]
		if !ok {
			continue
		}
		name := a.name
		if name == "" {
			name = a.text
		}
		if name == "" {
			continue
		}
		snap.Active = append(snap.Active, ActiveItem{
			Kind:      kind,
			Name:      name,
			Machine:   a.machine,
			Phase:     a.phase,
			LastLine:  a.lastLine,
			Done:      a.done,
			Expected:  a.expected,
			ElapsedMS: now.Sub(a.startedAt).Milliseconds(),
		})
	}
	sort.Slice(snap.Active, func(i, j int) bool { return snap.Active[i].ElapsedMS > snap.Active[j].ElapsedMS })
	const maxActive = 40
	if len(snap.Active) > maxActive {
		snap.Active = snap.Active[:maxActive]
	}

	return snap
}

// encodeDrvStates renders one byte per derivation — what the tree colours
// its dots by, and what the client filters the "active only" view on. Must
// be called with s.mu held.
func (s *state) encodeDrvStates() string {
	b := make([]byte, len(s.track))
	for i, t := range s.track {
		b[i] = t.state()
	}
	return base64.StdEncoding.EncodeToString(b)
}
