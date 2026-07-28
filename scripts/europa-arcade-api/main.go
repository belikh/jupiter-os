package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	minervaMagnet = "magnet:?xt=urn:btih:c1358e4763f8a5935109412b7d0db46ce9af238e&dn=Minerva_Myrient&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce"
	nfsRoot       = "/tank/archive/retro/games"
	torrentsDir   = "/var/cache/pegasus-torrents"
)

type DownloadStatus struct {
	Status  string  `json:"status"`
	Percent float64 `json:"percent"`
	Speed   string  `json:"speed"`
	ETA     string  `json:"eta"`
	Error   string  `json:"error,omitempty"`
}

func isSafePath(file string) bool {
	cleaned := filepath.Clean(file)

	// Reject absolute paths
	if filepath.IsAbs(cleaned) || strings.HasPrefix(cleaned, "/") || strings.HasPrefix(cleaned, "\\") {
		return false
	}

	// Reject directory traversal segments
	if strings.HasPrefix(cleaned, "..") || strings.Contains(cleaned, "../") || strings.Contains(cleaned, "..\\") {
		return false
	}

	return true
}

func normalizeFilePath(file string) string {
	// Convert 1g1r-collection/game.rom to 1g1r/collection/game.rom
	// The launcher passes collection names with hyphen instead of slash
	if strings.HasPrefix(file, "1g1r-") {
		// Find the first slash after 1g1r-
		parts := strings.Split(strings.TrimPrefix(file, "1g1r-"), "/")
		if len(parts) > 0 {
			// Rejoin: 1g1r / collection / game.rom
			return filepath.Join("1g1r", strings.Join(parts, "/"))
		}
	}
	return file
}

func main() {
	// Ensure transmission daemon is running
	ensureTransmission()

	// Ensure Minerva torrent is added
	ensureMinervaTorrent()

	http.HandleFunc("/api/download", handleDownload)
	http.HandleFunc("/api/download-status", handleStatus)
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	log.Printf("Europa arcade API listening on :8765")
	log.Fatal(http.ListenAndServe(":8765", nil))
}

func findFileIndex(file string) (string, error) {
	output, err := exec.Command("transmission-remote", "-t", "1", "--files").Output()
	if err != nil {
		return "", err
	}

	normalized := filepath.ToSlash(normalizeFilePath(file)) // e.g. "1g1r/nointro-nes/Super Mario Bros.nes"

	lines := strings.Split(string(output), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		// Line looks like: "145: Minerva_Myrient/1g1r/nointro-nes/Super Mario Bros.nes (45%)" or similar
		if !strings.Contains(line, ":") {
			continue
		}

		parts := strings.SplitN(line, ":", 2)
		if len(parts) < 2 {
			continue
		}

		index := strings.TrimSpace(parts[0])
		rest := strings.TrimSpace(parts[1])

		// Normalize backslashes/slashes
		restSlash := filepath.ToSlash(rest)

		// Check if the requested file path matches/is-part-of the torrent file path
		if strings.Contains(restSlash, normalized) {
			return index, nil
		}
	}

	return "", fmt.Errorf("file not found in torrent")
}

func getFilePercent(file string) (float64, error) {
	output, err := exec.Command("transmission-remote", "-t", "1", "--files").Output()
	if err != nil {
		return 0.0, err
	}

	normalized := filepath.ToSlash(normalizeFilePath(file))

	lines := strings.Split(string(output), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if !strings.Contains(line, ":") {
			continue
		}

		parts := strings.SplitN(line, ":", 2)
		if len(parts) < 2 {
			continue
		}

		rest := strings.TrimSpace(parts[1])
		restSlash := filepath.ToSlash(rest)

		if strings.Contains(restSlash, normalized) {
			// Find percentage in parenthesis at the end, e.g., " (45%)" or " (100%)"
			openParen := strings.LastIndex(line, "(")
			closeParen := strings.LastIndex(line, ")")
			if openParen != -1 && closeParen > openParen {
				pctStr := strings.TrimSuffix(line[openParen+1:closeParen], "%")
				if val, err := strconv.ParseFloat(pctStr, 64); err == nil {
					return val / 100.0, nil
				}
			}
		}
	}

	return 0.0, fmt.Errorf("file not found in torrent")
}

func handleDownload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	file := r.URL.Query().Get("file")
	if file == "" {
		http.Error(w, "missing file parameter", http.StatusBadRequest)
		return
	}

	if !isSafePath(file) {
		http.Error(w, "invalid or unsafe file path", http.StatusBadRequest)
		return
	}

	normalizedFile := normalizeFilePath(file)

	// Verify file doesn't already exist (if it does, no need to download)
	fullPath := filepath.Join(nfsRoot, normalizedFile)
	if fi, err := os.Stat(fullPath); err == nil && fi.Size() > 0 {
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(DownloadStatus{
			Status:  "complete",
			Percent: 1.0,
		})
		return
	}

	// Find the file index in the torrent
	index, err := findFileIndex(file)
	if err != nil {
		log.Printf("Failed to find file index for %s: %v", file, err)
		http.Error(w, "file not found in torrent", http.StatusNotFound)
		return
	}

	// Request download for only this file in Transmission
	log.Printf("Requesting download for file index %s: %s", index, file)
	if err := exec.Command("transmission-remote", "-t", "1", "-g", index).Run(); err != nil {
		log.Printf("Failed to set download priority for index %s: %v", index, err)
		http.Error(w, "failed to start download", http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusAccepted)
	json.NewEncoder(w).Encode(DownloadStatus{
		Status:  "downloading",
		Percent: 0.0,
	})
}

func handleStatus(w http.ResponseWriter, r *http.Request) {
	file := r.URL.Query().Get("file")
	if file == "" {
		http.Error(w, "missing file parameter", http.StatusBadRequest)
		return
	}

	if !isSafePath(file) {
		http.Error(w, "invalid or unsafe file path", http.StatusBadRequest)
		return
	}

	// Normalize file path: convert 1g1r-collection to 1g1r/collection
	normalizedFile := normalizeFilePath(file)

	// Check if file exists on NFS
	fullPath := filepath.Join(nfsRoot, normalizedFile)
	if fi, err := os.Stat(fullPath); err == nil && fi.Size() > 0 {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(DownloadStatus{
			Status:  "complete",
			Percent: 1.0,
			Speed:   "0 B/s",
			ETA:     "0s",
		})
		return
	}

	// File not on NFS yet, get the percentage of the specific file
	pct, err := getFilePercent(file)
	if err != nil {
		log.Printf("Failed to get file percent for status: %v", err)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(DownloadStatus{
			Status: "error",
			Error:  err.Error(),
		})
		return
	}

	// Get overall transmission status (for speed and ETA)
	status := getTransmissionStatus()
	status.Percent = pct
	if pct >= 1.0 {
		status.Status = "complete"
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(status)
}

func ensureTransmission() {
	cmd := exec.Command("transmission-daemon",
		"--download-dir", torrentsDir,
		"-w", torrentsDir)

	// Check if already running
	if err := exec.Command("transmission-remote", "--list").Run(); err == nil {
		return // Already running
	}

	// Start daemon
	cmd.Start()
	time.Sleep(2 * time.Second)
	log.Printf("Started transmission daemon")
}

func ensureMinervaTorrent() {
	// Check if Minerva torrent is already added
	output, err := exec.Command("transmission-remote", "--list").Output()
	if err == nil && strings.Contains(string(output), "Minerva_Myrient") {
		return // Already added
	}

	// Add torrent
	exec.Command("transmission-remote", "--add", minervaMagnet).Run()
	log.Printf("Added Minerva_Myrient torrent")

	// Wait 2 seconds for it to register and then set all files to do not download
	time.Sleep(2 * time.Second)
	exec.Command("transmission-remote", "-t", "1", "-G", "all").Run()
	log.Printf("Set all files in Minerva torrent to do not download")
}

func getTransmissionStatus() DownloadStatus {
	// Get Minerva torrent info
	output, err := exec.Command("transmission-remote", "-t", "1", "--info").Output()
	if err != nil {
		return DownloadStatus{
			Status: "error",
			Error:  "transmission not responding",
		}
	}

	status := DownloadStatus{
		Status:  "downloading",
		Percent: 0.1,
		Speed:   "calculating...",
		ETA:     "unknown",
	}

	lines := strings.Split(string(output), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)

		if strings.HasPrefix(line, "State:") {
			if strings.Contains(line, "Downloading") || strings.Contains(line, "Up & Down") {
				status.Status = "downloading"
			} else if strings.Contains(line, "Seeding") || strings.Contains(line, "Idle") {
				status.Status = "downloading"
			}
		}

		if strings.HasPrefix(line, "Percent Done:") {
			parts := strings.Fields(line)
			if len(parts) >= 3 {
				percent := strings.TrimSuffix(parts[2], "%")
				if val, err := strconv.ParseFloat(percent, 64); err == nil {
					status.Percent = val / 100.0
					if status.Percent >= 1.0 {
						status.Status = "complete"
					}
				}
			}
		}

		if strings.HasPrefix(line, "Download Speed:") {
			parts := strings.SplitN(line, "Download Speed:", 2)
			if len(parts) > 1 {
				status.Speed = strings.TrimSpace(parts[1])
			}
		}

		if strings.HasPrefix(line, "ETA:") {
			parts := strings.SplitN(line, "ETA:", 2)
			if len(parts) > 1 {
				status.ETA = strings.TrimSpace(parts[1])
			}
		}
	}

	return status
}
