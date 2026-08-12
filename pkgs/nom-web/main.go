package main

import (
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"time"
)

//go:embed static/*
var staticFS embed.FS

var logNameRe = regexp.MustCompile(`^(nom-[0-9]+\.jsonl|current\.jsonl)$`)

type logEntry struct {
	Name    string    `json:"name"`
	Size    int64     `json:"size"`
	ModTime time.Time `json:"modTime"`
	Live    bool      `json:"live"`
}

func listLogs(logDir string, m *manager) ([]logEntry, error) {
	entries, err := os.ReadDir(logDir)
	if err != nil {
		return nil, err
	}
	current := m.resolveCurrent()
	present := make(map[string]bool, len(entries))
	for _, e := range entries {
		present[e.Name()] = true
	}

	var out []logEntry
	for _, e := range entries {
		if e.IsDir() || !logNameRe.MatchString(e.Name()) {
			continue
		}
		// current.jsonl is a symlink to one of the nom-*.jsonl files beside
		// it, which is already listed (and flagged live). Listing it too
		// would duplicate the running run under a second name.
		if e.Name() == "current.jsonl" && present[current] {
			continue
		}
		// Stat, not e.Info(): the latter lstats, so a symlink would be
		// reported with the size and mtime of the link itself.
		info, err := os.Stat(filepath.Join(logDir, e.Name()))
		if err != nil {
			continue
		}
		out = append(out, logEntry{
			Name:    e.Name(),
			Size:    info.Size(),
			ModTime: info.ModTime(),
			Live:    e.Name() == current,
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ModTime.After(out[j].ModTime) })
	return out, nil
}

func main() {
	logDir := os.Getenv("NOMWEB_LOG_DIR")
	if logDir == "" {
		logDir = "/mnt/jupiter-ci-logs"
	}
	port := os.Getenv("NOMWEB_PORT")
	if port == "" {
		port = "8092"
	}

	m := newManager(logDir)
	mux := http.NewServeMux()

	mux.HandleFunc("/api/logs", func(w http.ResponseWriter, r *http.Request) {
		logs, err := listLogs(logDir, m)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(logs)
	})

	// The dependency forest for a run: fetched once per client and again
	// whenever a snapshot reports a larger treeSize, rather than being
	// re-sent with every snapshot.
	mux.HandleFunc("GET /api/logs/{name}/tree", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("name")
		if !logNameRe.MatchString(name) {
			http.Error(w, "invalid log name", http.StatusBadRequest)
			return
		}
		sess := m.getOrStart(name)
		sess.loadDeps() // CI may have written deps-<run>.txt after the session started
		tree, hasDeps := sess.st.treeSnapshot()

		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(struct {
			Tree
			HasDeps bool `json:"hasDeps"`
		}{tree, hasDeps})
	})

	mux.HandleFunc("GET /api/logs/{name}/stream", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("name")
		// Guard against path traversal / arbitrary reads off the NFS mount
		// even though the mux pattern already isolates the segment.
		if !logNameRe.MatchString(name) {
			http.Error(w, "invalid log name", http.StatusBadRequest)
			return
		}

		flusher, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, "streaming unsupported", http.StatusInternalServerError)
			return
		}

		sess := m.getOrStart(name)
		ch := sess.subscribe()
		defer sess.unsubscribe(ch)

		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("Connection", "keep-alive")
		w.WriteHeader(http.StatusOK)
		flusher.Flush()

		ctx := r.Context()
		for {
			select {
			case <-ctx.Done():
				return
			case snap := <-ch:
				b, err := json.Marshal(snap)
				if err != nil {
					continue
				}
				fmt.Fprintf(w, "data: %s\n\n", b)
				flusher.Flush()
				if snap.Finished {
					return
				}
			}
		}
	})

	staticContent, err := fs.Sub(staticFS, "static")
	if err != nil {
		log.Fatal(err)
	}
	mux.Handle("/", http.FileServer(http.FS(staticContent)))

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	log.Printf("nom-web listening on :%s, serving logs from %s", port, logDir)
	log.Fatal(srv.ListenAndServe())
}
