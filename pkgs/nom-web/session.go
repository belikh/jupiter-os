package main

import (
	"bufio"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// session owns exactly one file's parse. Multiple SSE clients watching the
// same file share this single reader/parser instead of each re-reading a
// (potentially multi-gigabyte) log from scratch.
type session struct {
	path string
	st   *state

	mu   sync.Mutex
	subs map[chan Snapshot]bool
	done bool
}

func newSession(path string) *session {
	return &session{
		path: path,
		st:   newState(),
		subs: make(map[chan Snapshot]bool),
	}
}

// depsPath is the edge list belonging to this log: nom-<run>.jsonl pairs
// with deps-<run>.txt. current.jsonl is resolved first so the live view
// finds the running run's graph.
func (sess *session) depsPath() string {
	base := filepath.Base(sess.path)
	if base == "current.jsonl" {
		if target, err := os.Readlink(sess.path); err == nil {
			base = filepath.Base(target)
		}
	}
	run := strings.TrimSuffix(strings.TrimPrefix(base, "nom-"), ".jsonl")
	if run == base {
		return ""
	}
	return filepath.Join(filepath.Dir(sess.path), "deps-"+run+".txt")
}

// loadDeps attaches the run's dependency graph if it is there. CI writes it
// before the first build starts, but a session can outrace that (and older
// runs predate it entirely), so this is retried from the tree endpoint
// rather than being a one-shot at session start.
func (sess *session) loadDeps() {
	sess.st.mu.Lock()
	already := sess.st.deps != nil
	sess.st.mu.Unlock()
	if already {
		return
	}

	path := sess.depsPath()
	if path == "" {
		return
	}
	g, err := loadDepGraph(path)
	if err != nil {
		return
	}

	sess.st.mu.Lock()
	sess.st.deps = g
	sess.st.tree = nil // force a rebuild now that the edges are known
	sess.st.mu.Unlock()
	log.Printf("nom-web: loaded dependency graph %s (%d derivations with inputs)", path, len(g.inputs))
}

func (sess *session) subscribe() chan Snapshot {
	ch := make(chan Snapshot, 1)
	sess.mu.Lock()
	sess.subs[ch] = true
	// Prime the new subscriber with the current picture immediately.
	sess.st.mu.Lock()
	snap := sess.st.snapshot(sess.done)
	sess.st.mu.Unlock()
	sess.mu.Unlock()
	select {
	case ch <- snap:
	default:
	}
	return ch
}

func (sess *session) unsubscribe(ch chan Snapshot) {
	sess.mu.Lock()
	delete(sess.subs, ch)
	sess.mu.Unlock()
}

func (sess *session) broadcast() {
	sess.st.mu.Lock()
	snap := sess.st.snapshot(sess.done)
	sess.st.mu.Unlock()

	sess.mu.Lock()
	defer sess.mu.Unlock()
	for ch := range sess.subs {
		select {
		case ch <- snap:
		default:
			// Slow subscriber: drop the stale pending snapshot, keep the
			// newest (safe because snapshots are idempotent full states,
			// not deltas).
			select {
			case <-ch:
			default:
			}
			select {
			case ch <- snap:
			default:
			}
		}
	}
}

// run streams the file from byte 0, applying events as they're read and
// broadcasting a throttled snapshot to subscribers. isLive reports whether
// `path` is still the target of current.jsonl — the same signal the
// existing `tail -F` CI workflow relies on. run exits (marking the session
// finished) once the file stops growing and is no longer the live target.
func (sess *session) run(isLive func(path string) bool) {
	f, err := os.Open(sess.path)
	if err != nil {
		log.Printf("nom-web: open %s: %v", sess.path, err)
		sess.mu.Lock()
		sess.done = true
		sess.mu.Unlock()
		sess.broadcast()
		return
	}
	defer f.Close()

	r := bufio.NewReaderSize(f, 1<<20)
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()

	lastBroadcast := time.Time{}
	idle := 0
	var pending strings.Builder

	for {
		chunk, err := r.ReadString('\n')
		if err == nil {
			// Complete line: whatever was pending, plus this chunk.
			line := chunk
			if pending.Len() > 0 {
				line = pending.String() + chunk
				pending.Reset()
			}
			if s := strings.TrimPrefix(line, "@nix "); s != line {
				var ev rawEvent
				if jerr := json.Unmarshal([]byte(s), &ev); jerr == nil {
					sess.st.mu.Lock()
					sess.st.apply(&ev)
					sess.st.mu.Unlock()
				}
			}
			idle = 0
			if time.Since(lastBroadcast) > 150*time.Millisecond {
				sess.broadcast()
				lastBroadcast = time.Now()
			}
			continue
		}

		// Hit EOF (or a read error) with a possibly-partial trailing line.
		// os.File reads past EOF keep returning io.EOF without going stale,
		// so the same *bufio.Reader keeps working once the writer appends
		// more — just remember the partial bytes so the eventual full line
		// isn't split across polls.
		pending.WriteString(chunk)

		if !isLive(sess.path) {
			idle++
			if idle >= 5 { // ~1s grace after losing "live" status, in case of a trailing write race
				break
			}
		}
		<-ticker.C
	}

	sess.mu.Lock()
	sess.done = true
	sess.mu.Unlock()
	sess.broadcast()
}

// manager keeps at most one session alive per file.
type manager struct {
	logDir string

	mu       sync.Mutex
	sessions map[string]*session
}

func newManager(logDir string) *manager {
	return &manager{logDir: logDir, sessions: make(map[string]*session)}
}

func (m *manager) resolveCurrent() string {
	target, err := os.Readlink(filepath.Join(m.logDir, "current.jsonl"))
	if err != nil {
		return ""
	}
	return filepath.Base(target)
}

func (m *manager) isLive(path string) bool {
	return filepath.Base(path) == m.resolveCurrent()
}

// getOrStart returns the (possibly already running) session for name,
// starting its reader goroutine on first access.
func (m *manager) getOrStart(name string) *session {
	m.mu.Lock()
	defer m.mu.Unlock()
	if s, ok := m.sessions[name]; ok {
		return s
	}
	s := newSession(filepath.Join(m.logDir, name))
	m.sessions[name] = s
	s.loadDeps()
	go s.run(m.isLive)
	return s
}
