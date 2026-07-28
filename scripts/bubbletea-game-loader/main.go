package main

import (
	"archive/zip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/bubbles/progress"
	"github.com/charmbracelet/lipgloss"
)

type tickMsg time.Time
type progressMsg struct {
	percent float64
	status  string
	detail  string
}
type statusPollMsg struct {
	status string
	err    error
}
type doneMsg struct{ err error }
type launchMsg struct{}

type model struct {
	gamePath    string
	gameTitle   string
	nfsRoot     string
	europaAddr  string
	progress    progress.Model
	percent     float64
	status      string
	detail      string
	err         error
	done        bool
	downloading bool
	ctx         context.Context
	cancelFunc  context.CancelFunc
}

var (
	titleStyle = lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color("#FAFAFA")).
		Background(lipgloss.Color("#1E1E2E")).
		Padding(0, 1).
		MarginBottom(1)

	statusStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("#A6ADC8")).
		MarginLeft(2)

	detailStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("#F9E2AF")).
		MarginLeft(2)

	progressStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("#F5E0DC")).
		MarginLeft(2)

	cancelStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("#F38BA8")).
		MarginLeft(2)

	errorStyle = lipgloss.NewStyle().
		Foreground(lipgloss.Color("#F38BA8")).
		MarginLeft(2)
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintf(os.Stderr, "Usage: %s <game-file-path>\n", os.Args[0])
		os.Exit(1)
	}

	gamePath := os.Args[1]
	gameTitle := strings.TrimSuffix(filepath.Base(gamePath), filepath.Ext(gamePath))
	nfsRoot := "/tank/archive/retro"
	europaAddr := "10.1.1.2:8765" // HTTP API on europa

	ctx, cancel := context.WithCancel(context.Background())
	m := model{
		gamePath:   gamePath,
		gameTitle:  gameTitle,
		nfsRoot:    nfsRoot,
		europaAddr: europaAddr,
		progress:   progress.New(progress.WithDefaultGradient()),
		status:     "Initializing...",
		ctx:        ctx,
		cancelFunc: cancel,
	}
	m.progress.Width = 60

	p := tea.NewProgram(m, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func (m model) Init() tea.Cmd {
	return tea.Batch(m.checkAndLaunch(), tickCmd())
}

func tickCmd() tea.Cmd {
	return tea.Tick(time.Millisecond*500, func(t time.Time) tea.Msg {
		return tickMsg(t)
	})
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		if msg.Type == tea.KeyCtrlC {
			m.cancelFunc()
			m.err = fmt.Errorf("cancelled by user")
			m.done = true
			return m, tea.Quit
		}

	case tickMsg:
		if m.downloading {
			return m, tea.Batch(
				m.pollDownloadStatus(),
				tickCmd(),
			)
		}
		if !m.done {
			return m, tickCmd()
		}
		return m, tea.Quit

	case statusPollMsg:
		if msg.err != nil {
			m.downloading = false
			m.done = true
			m.err = msg.err
			m.status = fmt.Sprintf("Download failed: %v", msg.err)
			return m, tea.Quit
		}
		if msg.status == "complete" {
			m.downloading = false
			m.percent = 1.0
			m.status = "Download complete, launching..."
			return m, m.doLaunch()
		}
		// Still downloading, will poll again on next tick
		return m, nil

	case progressMsg:
		m.percent = msg.percent
		m.status = msg.status
		m.detail = msg.detail
		// If we got a progress message indicating we're downloading, set the flag
		if msg.status == "Found on NFS" {
			return m, m.doLaunch()
		}
		if strings.Contains(msg.status, "Downloading") {
			m.downloading = true
		}
		return m, nil

	case launchMsg:
		m.done = true
		m.status = "Complete!"
		m.percent = 1.0
		return m, tea.Quit

	case doneMsg:
		m.done = true
		if msg.err != nil {
			m.err = msg.err
			m.status = fmt.Sprintf("Error: %v", msg.err)
		}
		return m, tea.Quit
	}

	return m, nil
}

func (m model) View() string {
	var b strings.Builder
	b.WriteString(titleStyle.Render(fmt.Sprintf("🎮 Loading: %s", m.gameTitle)))
	b.WriteString("\n\n")

	if m.err == nil {
		bar := m.progress.ViewAs(m.percent)
		b.WriteString(progressStyle.Render(bar))
		b.WriteString("\n\n")
		b.WriteString(statusStyle.Render(m.status))
		if m.detail != "" {
			b.WriteString("\n")
			b.WriteString(detailStyle.Render(m.detail))
		}
	} else {
		b.WriteString(errorStyle.Render(fmt.Sprintf("Error: %v", m.err)))
	}

	b.WriteString("\n\n")
	b.WriteString(cancelStyle.Render("Press Ctrl+C to cancel"))
	b.WriteString("\n")

	return b.String()
}

func (m model) checkAndLaunch() tea.Cmd {
	return func() tea.Msg {
		nfsPath := filepath.Join(m.nfsRoot, "games", m.gamePath)

		// Step 1: Check if file exists locally
		if _, err := os.Stat(nfsPath); err == nil {
			return progressMsg{
				percent: 1.0,
				status:  "Found on NFS",
				detail:  "Launching emulator...",
			}
		}

		// Step 2: File doesn't exist, request download from europa
		if err := m.requestDownload(); err != nil {
			return doneMsg{err: fmt.Errorf("download request failed: %w", err)}
		}

		// Step 3: Return a message that tells Update to start polling
		return progressMsg{
			percent: 0.0,
			status:  "Downloading from europa...",
			detail:  "Starting download...",
		}
	}
}

func (m model) pollDownloadStatus() tea.Cmd {
	return func() tea.Msg {
		status, err := m.getDownloadStatus()
		if err != nil {
			return statusPollMsg{err: fmt.Errorf("status poll failed: %w", err)}
		}

		m.percent = status.Percent
		m.detail = fmt.Sprintf("%s  •  %s", status.Speed, status.ETA)

		return statusPollMsg{
			status: status.Status,
			err:    nil,
		}
	}
}

func (m model) doLaunch() tea.Cmd {
	return func() tea.Msg {
		nfsPath := filepath.Join(m.nfsRoot, "games", m.gamePath)

		if err := m.launchEmulator(nfsPath); err != nil {
			return doneMsg{err: fmt.Errorf("launch failed: %w", err)}
		}

		return launchMsg{}
	}
}

type downloadStatus struct {
	Status  string  `json:"status"`   // "downloading", "complete", "error"
	Percent float64 `json:"percent"`
	Speed   string  `json:"speed"`
	ETA     string  `json:"eta"`
	Error   string  `json:"error"`
}

func (m model) requestDownload() error {
	url := fmt.Sprintf("http://%s:8765/api/download?file=%s",
		m.europaAddr, m.gamePath)

	resp, err := http.Post(url, "application/json", strings.NewReader("{}"))
	if err != nil {
		return fmt.Errorf("could not reach europa: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusAccepted {
		return fmt.Errorf("europa returned %d", resp.StatusCode)
	}

	return nil
}

func (m model) getDownloadStatus() (*downloadStatus, error) {
	url := fmt.Sprintf("http://%s:8765/api/download-status?file=%s",
		m.europaAddr, m.gamePath)

	resp, err := http.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var status downloadStatus
	if err := json.NewDecoder(resp.Body).Decode(&status); err != nil {
		return nil, err
	}

	return &status, nil
}

func (m model) launchEmulator(romPath string) error {
	// Check if romPath is a ZIP archive (curated collection)
	if strings.HasSuffix(strings.ToLower(romPath), ".zip") {
		// Extract to /tmp/pegasus-cache
		cachePath, err := m.extractZip(romPath)
		if err != nil {
			return fmt.Errorf("extraction failed: %w", err)
		}
		romPath = cachePath
	}

	// Determine emulator based on game collection
	emulator := m.getEmulator()
	if emulator == "" {
		return fmt.Errorf("unknown collection for %s", m.gamePath)
	}

	cmd := exec.CommandContext(m.ctx, emulator, romPath)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin

	return cmd.Run()
}

func (m model) extractZip(zipPath string) (string, error) {
	reader, err := zip.OpenReader(zipPath)
	if err != nil {
		return "", err
	}
	defer reader.Close()

	// Create destination directory in /tmp/pegasus-cache
	cacheDir := "/tmp/pegasus-cache"
	os.MkdirAll(cacheDir, 0755)

	// Extract first file (or find the main executable/game file)
	var extractedPath string
	for _, file := range reader.File {
		// Skip directories
		if file.FileInfo().IsDir() {
			continue
		}

		// Extract to cache directory
		src, err := file.Open()
		if err != nil {
			return "", err
		}
		defer src.Close()

		destPath := filepath.Join(cacheDir, filepath.Base(file.Name))
		dest, err := os.Create(destPath)
		if err != nil {
			return "", err
		}
		defer dest.Close()

		if _, err := io.Copy(dest, src); err != nil {
			return "", err
		}

		// Use the first file extracted
		if extractedPath == "" {
			extractedPath = destPath
		}
	}

	if extractedPath == "" {
		return "", fmt.Errorf("no files found in archive")
	}

	return extractedPath, nil
}

func (m model) getEmulator() string {
	switch {
	case strings.Contains(m.gamePath, "nointro-nes"):
		return "retroarch"
	case strings.Contains(m.gamePath, "nointro-snes"):
		return "retroarch"
	case strings.Contains(m.gamePath, "redump-ps1"):
		return "retroarch"
	case strings.Contains(m.gamePath, "exo-dos"):
		return "dosbox-staging"
	case strings.Contains(m.gamePath, "exo-win3x"):
		return "dosbox-x"
	default:
		return "retroarch"
	}
}

func humanBytes(b int64) string {
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := int64(unit), 0
	for n := b / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(b)/float64(div), "KMGTPE"[exp])
}
