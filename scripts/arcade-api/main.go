package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

type DownloadJob struct {
	ID        string
	GamePath  string
	Status    string
	Percent   float64
	Speed     string
	ETA       string
	Error     string
	StartTime time.Time
	cmd       *exec.Cmd
	cancel    context.CancelFunc
}

var (
	jobs      map[string]*DownloadJob
	jobsMutex sync.RWMutex
	nextJobID int

	metadataCache map[string]map[string]int
	cacheMutex    sync.RWMutex

	collectionTorrent = map[string]string{
		"1g1r-nointro-nes":      "Minerva_Myrient - No-Intro - Nintendo - Nintendo Entertainment System*.torrent",
		"1g1r-nointro-snes":     "Minerva_Myrient - No-Intro - Nintendo - Super Nintendo Entertainment System*.torrent",
		"1g1r-nointro-gb":       "Minerva_Myrient - No-Intro - Nintendo - Game Boy*.torrent",
		"1g1r-nointro-gbc":      "Minerva_Myrient - No-Intro - Nintendo - Game Boy Color*.torrent",
		"1g1r-nointro-gba":      "Minerva_Myrient - No-Intro - Nintendo - Game Boy Advance*.torrent",
		"1g1r-nointro-n64":      "Minerva_Myrient - No-Intro - Nintendo - Nintendo 64*.torrent",
		"1g1r-nointro-ds":       "Minerva_Myrient - No-Intro - Nintendo - Nintendo DS*.torrent",
		"1g1r-redump-ps1":       "Minerva_Myrient - Redump - Sony - PlayStation*.torrent",
		"1g1r-redump-ps2":       "Minerva_Myrient - Redump - Sony - PlayStation 2*.torrent",
		"1g1r-redump-psp":       "Minerva_Myrient - Redump - Sony - PlayStation Portable*.torrent",
		"1g1r-redump-saturn":    "Minerva_Myrient - Redump - Sega - Saturn*.torrent",
		"1g1r-redump-dreamcast": "Minerva_Myrient - Redump - Sega - Dreamcast*.torrent",
		"1g1r-redump-gamecube":  "Minerva_Myrient - Redump - Nintendo - GameCube*.torrent",
		"1g1r-redump-wii":       "Minerva_Myrient - Redump - Nintendo - Wii*.torrent",
		"1g1r-redump-xbox":      "Minerva_Myrient - Redump - Microsoft - Xbox*.torrent",
	}

	torrentDir = "/tank/archive/retro/metadata/minerva-torrents"
	cacheDir   = "/tank/archive/retro/games"
)

func init() {
	jobs = make(map[string]*DownloadJob)
	metadataCache = make(map[string]map[string]int)
	os.MkdirAll(cacheDir, 0755)
	loadMetadataCache()
}

func loadMetadataCache() {
	metadataDir := "/tank/archive/retro/metadata/minerva-ids"
	files, err := filepath.Glob(filepath.Join(metadataDir, "*.json"))
	if err != nil {
		log.Printf("Warning: could not read metadata dir: %v", err)
		return
	}
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			log.Printf("Warning: could not read %s: %v", f, err)
			continue
		}
		var m map[string]interface{}
		if err := json.Unmarshal(data, &m); err != nil {
			log.Printf("Warning: invalid JSON in %s: %v", f, err)
			continue
		}
		if filesMap, ok := m["files"].(map[string]interface{}); ok {
			indexMap := make(map[string]int)
			for gameName, idx := range filesMap {
				switch v := idx.(type) {
				case float64:
					indexMap[gameName] = int(v)
				case string:
					if i, err := strconv.Atoi(v); err == nil {
						indexMap[gameName] = i
					}
				}
			}
			cacheMutex.Lock()
			metadataCache[filepath.Base(f)] = indexMap
			cacheMutex.Unlock()
		}
	}
	log.Printf("Loaded metadata cache: %d files", len(metadataCache))
}

func handleDownload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	gamePath := r.URL.Query().Get("file")
	if gamePath == "" {
		http.Error(w, "Missing file parameter", http.StatusBadRequest)
		return
	}

	parts := strings.SplitN(gamePath, "/", 2)
	if len(parts) != 2 {
		http.Error(w, fmt.Sprintf("Invalid game path format: %s", gamePath), http.StatusBadRequest)
		return
	}

	collection := parts[0]
	gameName := parts[1]

	torrentPattern, hasCollection := collectionTorrent[collection]
	if !hasCollection {
		http.Error(w, fmt.Sprintf("Unknown collection: %s", collection), http.StatusNotFound)
		return
	}

	// Find the torrent file matching the pattern
	matches, err := filepath.Glob(filepath.Join(torrentDir, torrentPattern))
	if err != nil || len(matches) == 0 {
		http.Error(w, fmt.Sprintf("Torrent not found for %s", collection), http.StatusNotFound)
		return
	}

	torrentFile := matches[0]

	jobID := fmt.Sprintf("job-%d", nextJobID)
	nextJobID++

	outputFile := filepath.Join(cacheDir, filepath.Base(gameName))

	job := &DownloadJob{
		ID:        jobID,
		GamePath:  gamePath,
		Status:    "Starting",
		StartTime: time.Now(),
	}

	jobsMutex.Lock()
	jobs[jobID] = job
	jobsMutex.Unlock()

	go downloadViaAria2c(job, torrentFile, gameName, outputFile)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"job_id": jobID, "status": "accepted"})
}

func downloadViaAria2c(job *DownloadJob, torrentFile, gameName, outputFile string) {
	job.Status = "Downloading"
	log.Printf("Job %s: Downloading %s from %s", job.ID, gameName, torrentFile)

	fileIndex, err := getFileIndexFromMetadata(gameName, torrentFile)
	if err != nil {
		job.Status = "Error"
		job.Error = fmt.Sprintf("Metadata lookup failed: %v", err)
		log.Printf("Job %s: Metadata error: %v", job.ID, err)
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	job.cancel = cancel

	cmd := exec.CommandContext(ctx, "aria2c",
		"--select-file", fileIndex,
		"-d", cacheDir,
		"-o", filepath.Base(gameName),
		"--seed-time=0",
		"--bt-stop-timeout=60",
		"--check-integrity=true",
		"--max-tries=3",
		"-x", "16",
		torrentFile,
	)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		job.Status = "Error"
		job.Error = fmt.Sprintf("Setup error: %v", err)
		return
	}

	if err := cmd.Start(); err != nil {
		job.Status = "Error"
		job.Error = fmt.Sprintf("Failed to start download: %v", err)
		log.Printf("Job %s: Start error: %v", job.ID, err)
		return
	}

	job.cmd = cmd

	scanner := bufio.NewScanner(stdout)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.Contains(line, "%) CN:") || strings.Contains(line, "% CN:") {
			parts := strings.Fields(line)
			for i, p := range parts {
				if strings.HasSuffix(p, "%") {
					pct := strings.TrimSuffix(p, "%")
					if f, err := strconv.ParseFloat(pct, 64); err == nil {
						job.Percent = f / 100.0
					}
				}
				if strings.HasSuffix(p, "B/s") || strings.HasSuffix(p, "KB/s") || strings.HasSuffix(p, "MB/s") {
					job.Speed = p
				}
				if i > 0 && strings.HasPrefix(parts[i-1], "ETA:") {
					job.ETA = p
				}
			}
		}
	}

	if err := cmd.Wait(); err != nil {
		job.Status = "Error"
		job.Error = fmt.Sprintf("Download failed: %v", err)
		log.Printf("Job %s: Wait error: %v", job.ID, err)
		return
	}

	downloadedFile := filepath.Join(cacheDir, filepath.Base(gameName))
	if _, err := os.Stat(downloadedFile); err != nil {
		job.Status = "Error"
		job.Error = fmt.Sprintf("File not found after download: %v", err)
		log.Printf("Job %s: File missing: %s", job.ID, downloadedFile)
		return
	}

	job.Status = "Complete"
	job.Percent = 1.0
	log.Printf("Job %s: Complete - %s", job.ID, downloadedFile)
}

func getFileIndexFromMetadata(gameName, torrentFile string) (string, error) {
	cacheMutex.RLock()
	defer cacheMutex.RUnlock()

	for _, indexMap := range metadataCache {
		if idx, ok := indexMap[gameName]; ok {
			return strconv.Itoa(idx), nil
		}
	}

	return "", fmt.Errorf("game not found in metadata: %s", gameName)
}

func handleStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	jobID := r.URL.Query().Get("jobid")
	if jobID == "" {
		http.Error(w, "Missing jobid parameter", http.StatusBadRequest)
		return
	}

	jobsMutex.RLock()
	job, exists := jobs[jobID]
	jobsMutex.RUnlock()

	if !exists {
		http.Error(w, "Job not found", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(job)
}

func main() {
	http.HandleFunc("/api/download", handleDownload)
	http.HandleFunc("/api/download-status", handleStatus)
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintf(w, "OK")
	})

	addr := "0.0.0.0:8765"
	log.Printf("Arcade API starting on %s", addr)
	if err := http.ListenAndServe(addr, nil); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
