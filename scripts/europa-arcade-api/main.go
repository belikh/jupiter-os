package main

import (
	"encoding/json"
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
	// Transmission daemon is managed by systemd service, runs 24/7 to seed Minerva
	// Just ensure the Minerva torrent is added to transmission
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

	// Normalize file path: convert 1g1r-collection to 1g1r/collection
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

	// File doesn't exist, request transmission to download it
	// For now, just ensure the Minerva torrent is active and seeding
	log.Printf("Download requested for: %s (normalized: %s)", file, normalizedFile)

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

	// File not on NFS yet, check transmission torrent status
	status := getTransmissionStatus()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(status)
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
}

func getTransmissionStatus() DownloadStatus {
	// List torrents to find Minerva_Myrient
	listOutput, err := exec.Command("transmission-remote", "--list").Output()
	if err != nil {
		return DownloadStatus{
			Status: "error",
			Error:  "transmission not responding",
		}
	}

	// Find the Minerva torrent ID
	var minervaID string
	lines := strings.Split(string(listOutput), "\n")
	for _, line := range lines {
		if strings.Contains(line, "Minerva_Myrient") {
			parts := strings.Fields(line)
			if len(parts) > 0 {
				minervaID = strings.TrimSpace(parts[0])
				break
			}
		}
	}

	if minervaID == "" {
		// Minerva torrent not found, might still be seeding but not listed
		return DownloadStatus{
			Status: "downloading",
			Percent: 0.0,
			Speed:   "seeding",
			ETA:     "indefinite",
		}
	}

	// Get info for Minerva torrent
	output, err := exec.Command("transmission-remote", "-t", minervaID, "--info").Output()
	if err != nil {
		return DownloadStatus{
			Status: "error",
			Error:  "could not query torrent status",
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
