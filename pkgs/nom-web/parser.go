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

// storePathToName mirrors nix's storePathToName: baseName minus the
// "<hash>-" prefix.
func storePathToName(path string) string {
	base := path
	if i := strings.LastIndexByte(path, '/'); i >= 0 {
		base = path[i+1:]
	}
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

	startTime time.Time
	lastEvent time.Time
	events    uint64
}

func newState() *state {
	now := time.Now()
	return &state{
		activities:  make(map[uint64]*activity),
		byType:      make(map[ActivityType]*typeAgg),
		recentLines: newRing(200),
		warnings:    newRing(100),
		startTime:   now,
		lastEvent:   now,
	}
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
			expectedByType: make(map[ActivityType]uint64),
			startedAt:      time.Now(),
		}
		s.activities[ev.ID] = a
		s.agg(t).active[ev.ID] = true

		switch t {
		case actBuild:
			if path, ok := fieldStr(ev.Fields, 0); ok {
				a.name = storePathToNameWithoutDrvSuffix(path)
			}
			if m, ok := fieldStr(ev.Fields, 1); ok {
				a.machine = m
			}
		case actSubstitute:
			if path, ok := fieldStr(ev.Fields, 0); ok {
				a.name = storePathToName(path)
			}
			if sub, ok := fieldStr(ev.Fields, 1); ok {
				a.machine = sub
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
	}
}
