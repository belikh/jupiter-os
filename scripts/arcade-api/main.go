package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
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
}

var (
	jobs      map[string]*DownloadJob
	jobsMutex sync.RWMutex
	nextJobID int

	collectionTorrent = map[string]string{
		"1g1r-nointro-nes":      "Minerva_Myrient_-_No-Intro_-_Nintendo_-_Nintendo_Entertainment_System*.torrent",
		"1g1r-nointro-snes":     "Minerva_Myrient_-_No-Intro_-_Nintendo_-_Super_Nintendo_Entertainment_System*.torrent",
		"1g1r-nointro-gb":       "Minerva_Myrient_-_No-Intro_-_Nintendo_-_Game_Boy*.torrent",
		"1g1r-nointro-gbc":      "Minerva_Myrient_-_No-Intro_-_Nintendo_-_Game_Boy_Color*.torrent",
		"1g1r-nointro-gba":      "Minerva_Myrient_-_No-Intro_-_Nintendo_-_Game_Boy_Advance*.torrent",
		"1g1r-nointro-n64":      "Minerva_Myrient_-_No-Intro_-_Nintendo_-_Nintendo_64*.torrent",
		"1g1r-nointro-ds":       "Minerva_Myrient_-_No-Intro_-_Nintendo_-_Nintendo_DS*.torrent",
		"1g1r-redump-ps1":       "Minerva_Myrient_-_Redump_-_Sony_-_PlayStation*.torrent",
		"1g1r-redump-ps2":       "Minerva_Myrient_-_Redump_-_Sony_-_PlayStation_2*.torrent",
		"1g1r-redump-psp":       "Minerva_Myrient_-_Redump_-_Sony_-_PlayStation_Portable*.torrent",
		"1g1r-redump-saturn":    "Minerva_Myrient_-_Redump_-_Sega_-_Saturn*.torrent",
		"1g1r-redump-dreamcast": "Minerva_Myrient_-_Redump_-_Sega_-_Dreamcast*.torrent",
		"1g1r-redump-gamecube":  "Minerva_Myrient_-_Redump_-_Nintendo_-_GameCube*.torrent",
		"1g1r-redump-wii":       "Minerva_Myrient_-_Redump_-_Nintendo_-_Wii*.torrent",
		"1g1r-redump-xbox":      "Minerva_Myrient_-_Redump_-_Microsoft_-_Xbox*.torrent",
	}

	torrentDir = "/tank/archive/retro/metadata/minerva-torrents"
	cacheDir   = "/var/cache/pegasus-roms"
)

func init() {
	jobs = make(map[string]*DownloadJob)
	os.MkdirAll(cacheDir, 0755)
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

	cmd := exec.Command("aria2c",
		"--select-file", gameName,
		"-d", cacheDir,
		"-o", filepath.Base(gameName),
		torrentFile,
	)

	err := cmd.Run()
	if err != nil {
		job.Status = "Error"
		job.Error = fmt.Sprintf("Download failed: %v", err)
		log.Printf("Job %s: Error: %v", job.ID, err)
		return
	}

	job.Status = "Complete"
	job.Percent = 1.0
	log.Printf("Job %s: Complete", job.ID)
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

	log.Println("Arcade API starting on :8765")
	if err := http.ListenAndServe(":8765", nil); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
