package main

// Wire format: nix's `--log-format internal-json`, one JSON object per line
// prefixed with "@nix ". The ActivityType/ResultType enum values and the
// aggregation rules below are taken from nix's own reference consumer of
// this stream (src/libmain/progress-bar.cc in NixOS/nix) and its enum
// definitions (src/libutil/include/nix/util/logging.hh) — nix's own
// progress bar is the canonical spec for how to interpret these events,
// which is what nom (nix-output-monitor) also parses.

import (
	"regexp"
	"strings"
	"sync"
	"time"
)

type ActivityType int

const (
	actUnknown       ActivityType = 0
	actCopyPath      ActivityType = 100
	actFileTransfer  ActivityType = 101
	actRealise       ActivityType = 102
	actCopyPaths     ActivityType = 103
	actBuilds        ActivityType = 104
	actBuild         ActivityType = 105
	actOptimiseStore ActivityType = 106
	actVerifyPaths   ActivityType = 107
	actSubstitute    ActivityType = 108
	actQueryPathInfo ActivityType = 109
	actPostBuildHook ActivityType = 110
	actBuildWaiting  ActivityType = 111
	actFetchTree     ActivityType = 112
)

type ResultType int

const (
	resFileLinked       ResultType = 100
	resBuildLogLine     ResultType = 101
	resUntrustedPath    ResultType = 102
	resCorruptedPath    ResultType = 103
	resSetPhase         ResultType = 104
	resProgress         ResultType = 105
	resSetExpected      ResultType = 106
	resPostBuildLogLine ResultType = 107
	resFetchStatus      ResultType = 108
)

// rawEvent is one decoded "@nix {...}" line. Fields is left as
// []interface{} because nix's Field variant is either a uint64 or a string
// and Go's encoding/json already decodes that unambiguously (numbers ->
// float64, strings -> string).
type rawEvent struct {
	Action string        `json:"action"`
	ID     uint64        `json:"id"`
	Level  int           `json:"level"`
	Parent uint64        `json:"parent"`
	Text   string        `json:"text"`
	Type   int           `json:"type"`
	Fields []interface{} `json:"fields"`
	Msg    string        `json:"msg"`
}

func fieldStr(f []interface{}, i int) (string, bool) {
	if i >= len(f) {
		return "", false
	}
	s, ok := f[i].(string)
	return s, ok
}

func fieldUint(f []interface{}, i int) (uint64, bool) {
	if i >= len(f) {
		return 0, false
	}
	n, ok := f[i].(float64)
	if !ok || n < 0 {
		return 0, false
	}
	return uint64(n), true
}

// storePathBase is the "<hash>-<name>" basename, which is what the
// deps-<run_id>.txt edge list is keyed by (nix-store --graph emits
// basenames, not full paths).
func storePathBase(path string) string {
	if i := strings.LastIndexByte(path, '/'); i >= 0 {
		return path[i+1:]
	}
	return path
}

// storePathToName mirrors nix's storePathToName: baseName minus the
// "<hash>-" prefix.
func storePathToName(path string) string {
	base := storePathBase(path)
	if i := strings.IndexByte(base, '-'); i >= 0 {
		return base[i+1:]
	}
	return ""
}

func storePathToNameWithoutDrvSuffix(path string) string {
	name := storePathToName(path)
	return strings.TrimSuffix(name, ".drv")
}

type activity struct {
	id                              uint64
	typ                             ActivityType
	parent                          uint64
	text                            string
	name                            string
	node                            int // index into state.drvs, or -1 — ties an activity to its tree node
	machine                         string
	phase                           string
	lastLine                        string
	done, expected, running, failed uint64
	expectedByType                  map[ActivityType]uint64
	startedAt                       time.Time
}

type typeAgg struct {
	done, expected, failed uint64
	active                 map[uint64]bool
}

func newTypeAgg() *typeAgg {
	return &typeAgg{active: make(map[uint64]bool)}
}

// ring is a fixed-capacity FIFO of strings, used to cap memory for
// build-log/warning panes regardless of how large the source file is.
type ring struct {
	buf []string
	cap int
}

func newRing(cap int) *ring { return &ring{cap: cap} }

func (r *ring) push(s string) {
	r.buf = append(r.buf, s)
	if len(r.buf) > r.cap {
		r.buf = r.buf[len(r.buf)-r.cap:]
	}
}

func (r *ring) items() []string {
	out := make([]string, len(r.buf))
	copy(out, r.buf)
	return out
}

var runHeaderRe = regexp.MustCompile(`=== jupiter-ci (\S+): (.+) ===`)

type state struct {
	mu sync.Mutex

	title string

	activities map[uint64]*activity
	byType     map[ActivityType]*typeAgg

	filesLinked, bytesLinked       uint64
	corruptedPaths, untrustedPaths uint64

	recentLines *ring
	warnings    *ring

	// Dependency tree. drvs is every derivation the run touches, in the
	// order nix listed/started them; track is one entry per derivation,
	// parallel to it. deps is the out-of-band edge list (nil until the
	// deps-<run_id>.txt file shows up, and forever if it never does — the
	// tree then degrades to a flat root list rather than disappearing).
	drvs      []string
	drvIndex  map[string]int
	nameIndex map[string]int // derivation name -> index, -1 once ambiguous
	track     []drvTrack
	inPlanned bool
	deps      *depGraph
	tree      *Tree
	treeFor   int // len(drvs) the cached tree was built from

	startTime time.Time
	lastEvent time.Time
	events    uint64
}

// drvTrack is what a derivation is doing right now. Counters rather than a
// single state because nix opens more than one activity per derivation (a
// build on the remote builder plus the local one carrying its log, and a
// path can be copied from several places at once) — collapsing that to a
// state would flip a derivation to "done" the moment the first of its
// activities stopped, while it was still building.
type drvTrack struct {
	building     int
	transferring int
	done         bool
}

// The rendered state, one byte per derivation, base64'd into the snapshot so
// a full 1000+ derivation picture costs ~2 KB per push rather than a
// re-serialised object graph.
const (
	drvPlanned      uint8 = 0
	drvRunning      uint8 = 1
	drvDone         uint8 = 2
	drvTransferring uint8 = 3
)

func (t drvTrack) state() uint8 {
	switch {
	case t.building > 0:
		return drvRunning
	case t.transferring > 0:
		return drvTransferring
	case t.done:
		return drvDone
	}
	return drvPlanned
}

func newState() *state {
	now := time.Now()
	return &state{
		activities:  make(map[uint64]*activity),
		byType:      make(map[ActivityType]*typeAgg),
		recentLines: newRing(200),
		warnings:    newRing(100),
		drvIndex:    make(map[string]int),
		nameIndex:   make(map[string]int),
		startTime:   now,
		lastEvent:   now,
	}
}

// noteDrv records a derivation the run touches and returns its index,
// registering it on first sight. Both the planned listing and build starts
// feed this: a run whose listing was suppressed (nix only prints it above a
// verbosity threshold) still gets a tree of whatever actually built.
// Must be called with s.mu held.
func (s *state) noteDrv(drv string) int {
	if i, ok := s.drvIndex[drv]; ok {
		return i
	}
	i := len(s.drvs)
	s.drvIndex[drv] = i
	s.drvs = append(s.drvs, drv)
	s.track = append(s.track, drvTrack{})

	// Copies and downloads name an output path, never the derivation that
	// produced it, and the edge list only relates derivations — so they are
	// attached to the tree by name. A name shared by more than one
	// derivation is poisoned rather than guessed at.
	name := storePathToNameWithoutDrvSuffix(drv)
	if name != "" {
		if _, dup := s.nameIndex[name]; dup {
			s.nameIndex[name] = -1
		} else {
			s.nameIndex[name] = i
		}
	}
	return i
}

// attachTransfer ties a copy/substitution of an output path to the tree node
// of the derivation that produced it. The edge list only relates
// derivations, and nix never names the derivation in a copy event, so the
// join is by name — declined outright when the path is not a store path, or
// when the name belongs to no derivation in this run (very common: most of
// what a run downloads was never going to be built) or to more than one.
// Must be called with s.mu held.
func (s *state) attachTransfer(a *activity, path string) {
	if !strings.HasPrefix(path, "/nix/store/") {
		return
	}
	name := storePathToName(path)
	if name == "" {
		return
	}
	i, ok := s.nameIndex[name]
	if !ok || i < 0 {
		return
	}
	a.node = i
	s.track[i].transferring++
}

// treeSnapshot returns the run's dependency forest, rebuilding it only when
// derivations have been added since the last call. It takes s.mu itself and
// drops it for the rebuild: that walk is O(graph) over a six-figure edge
// list, and holding the lock through it would stall the reader goroutine
// mid-parse.
func (s *state) treeSnapshot() (Tree, bool) {
	s.mu.Lock()
	if s.tree != nil && s.treeFor == len(s.drvs) {
		t, hasDeps := *s.tree, s.deps != nil
		s.mu.Unlock()
		return t, hasDeps
	}
	drvs := append([]string(nil), s.drvs...)
	g := s.deps
	s.mu.Unlock()

	t := buildTree(drvs, g)

	s.mu.Lock()
	s.tree = &t
	s.treeFor = len(drvs)
	s.mu.Unlock()
	return t, g != nil
}

func (s *state) agg(t ActivityType) *typeAgg {
	a, ok := s.byType[t]
	if !ok {
		a = newTypeAgg()
		s.byType[t] = a
	}
	return a
}

// apply mutates state from one decoded event. Must be called with s.mu held.
func (s *state) apply(ev *rawEvent) {
	s.events++
	s.lastEvent = time.Now()

	switch ev.Action {
	case "start":
		t := ActivityType(ev.Type)
		a := &activity{
			id:             ev.ID,
			typ:            t,
			parent:         ev.Parent,
			text:           ev.Text,
			node:           -1,
			expectedByType: make(map[ActivityType]uint64),
			startedAt:      time.Now(),
		}
		s.activities[ev.ID] = a
		s.agg(t).active[ev.ID] = true

		switch t {
		case actBuild:
			if path, ok := fieldStr(ev.Fields, 0); ok {
				a.name = storePathToNameWithoutDrvSuffix(path)
				a.node = s.noteDrv(storePathBase(path))
				s.track[a.node].building++
			}
			if m, ok := fieldStr(ev.Fields, 1); ok {
				a.machine = m
			}
		case actSubstitute:
			if path, ok := fieldStr(ev.Fields, 0); ok {
				a.name = storePathToName(path)
				s.attachTransfer(a, path)
			}
			if sub, ok := fieldStr(ev.Fields, 1); ok {
				a.machine = sub
			}
		case actCopyPath:
			// Naming is left alone here (the ACTIVE table shows nix's own
			// "copying path '…' from '…'" text); this only ties the copy to
			// the derivation that produced the path, so the tree keeps
			// showing a run's upload/download phase after building stops.
			if path, ok := fieldStr(ev.Fields, 0); ok {
				s.attachTransfer(a, path)
			}
		case actPostBuildHook:
			if path, ok := fieldStr(ev.Fields, 0); ok {
				a.name = storePathToNameWithoutDrvSuffix(path)
			}
		case actQueryPathInfo:
			if path, ok := fieldStr(ev.Fields, 0); ok {
				a.name = storePathToName(path)
			}
			if sub, ok := fieldStr(ev.Fields, 1); ok {
				a.machine = sub
			}
		}

	case "stop":
		a, ok := s.activities[ev.ID]
		if !ok {
			return
		}
		if a.node >= 0 && a.node < len(s.track) {
			t := &s.track[a.node]
			switch a.typ {
			case actBuild:
				if t.building > 0 {
					t.building--
				}
				t.done = true
			default:
				if t.transferring > 0 {
					t.transferring--
				}
			}
		}
		agg := s.agg(a.typ)
		agg.done += a.done
		agg.failed += a.failed
		for t, exp := range a.expectedByType {
			s.agg(t).expected -= exp
		}
		delete(agg.active, ev.ID)
		delete(s.activities, ev.ID)

	case "result":
		a, ok := s.activities[ev.ID]
		rt := ResultType(ev.Type)
		switch rt {
		case resFileLinked:
			s.filesLinked++
			if n, ok := fieldUint(ev.Fields, 0); ok {
				s.bytesLinked += n
			}
		case resBuildLogLine, resPostBuildLogLine:
			line, lok := fieldStr(ev.Fields, 0)
			if !lok {
				return
			}
			line = strings.TrimRight(line, "\r\n")
			if a != nil {
				a.lastLine = line
			}
			prefix := "unnamed"
			if a != nil && a.name != "" {
				prefix = a.name
			}
			if rt == resPostBuildLogLine {
				prefix += " (post)"
			}
			s.recentLines.push(prefix + "> " + line)
		case resUntrustedPath:
			s.untrustedPaths++
		case resCorruptedPath:
			s.corruptedPaths++
		case resSetPhase:
			if !ok {
				return
			}
			if phase, ok := fieldStr(ev.Fields, 0); ok {
				a.phase = phase
			}
		case resProgress:
			if !ok {
				return
			}
			done, _ := fieldUint(ev.Fields, 0)
			expected, _ := fieldUint(ev.Fields, 1)
			running, _ := fieldUint(ev.Fields, 2)
			failed, _ := fieldUint(ev.Fields, 3)
			a.done, a.expected, a.running, a.failed = done, expected, running, failed
		case resSetExpected:
			if !ok {
				return
			}
			expType, ok1 := fieldUint(ev.Fields, 0)
			expected, ok2 := fieldUint(ev.Fields, 1)
			if !ok1 || !ok2 {
				return
			}
			t := ActivityType(expType)
			agg := s.agg(t)
			agg.expected -= a.expectedByType[t]
			a.expectedByType[t] = expected
			agg.expected += expected
		case resFetchStatus:
			if !ok {
				return
			}
			if line, ok := fieldStr(ev.Fields, 0); ok {
				a.lastLine = line
			}
		}

	case "msg":
		if m := runHeaderRe.FindStringSubmatch(ev.Msg); m != nil {
			s.title = "jupiter-ci " + m[1] + ": " + m[2]
		}
		if ev.Level <= 1 && ev.Msg != "" {
			s.warnings.push(ev.Msg)
		}
		// nix announces the plan as a header msg followed by one indented
		// store path per line — the only place the derivations that haven't
		// started yet are ever named, and so the only way the tree can show
		// what a run is still waiting on.
		switch {
		case strings.HasSuffix(ev.Msg, "derivations will be built:"):
			s.inPlanned = true
		case s.inPlanned:
			path := strings.TrimSpace(ev.Msg)
			if strings.HasPrefix(path, "/nix/store/") && strings.HasSuffix(path, ".drv") {
				s.noteDrv(storePathBase(path))
			} else {
				s.inPlanned = false
			}
		}
	}
}
