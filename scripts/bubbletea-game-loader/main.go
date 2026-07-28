package main

import (
	"context"
	"encoding/json"
	"fmt"
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
type doneMsg struct{ err error }
type launchMsg struct{}

type model struct {
	gamePath   string
	gameTitle  string
	nfsRoot    string
	europaAddr string
	progress   progress.Model
	percent    float64
	status     string
	detail     string
	err        error
	done       bool
	ctx        context.Context
	cancelFunc context.CancelFunc
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
		if !m.done {
			return m, tickCmd()
		}
		return m, tea.Quit

	case progressMsg:
		m.percent = msg.percent
		m.status = msg.status
		m.detail = msg.detail
		return m, tickCmd()

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

		// Step 3: Poll for file availability
		if err := m.waitForFile(nfsPath); err != nil {
			return doneMsg{err: fmt.Errorf("download timeout: %w", err)}
		}

		// Step 4: Launch emulator
		if err := m.launchEmulator(nfsPath); err != nil {
			return doneMsg{err: fmt.Errorf("launch failed: %w", err)}
		}

		return launchMsg{}
	}
}

func (m model) requestDownload() error {
	reqBody := map[string]string{
		"file": m.gamePath,
	}
	body, _ := json.Marshal(reqBody)

	resp, err := http.Post(
		fmt.Sprintf("http://%s/api/download", m.europaAddr),
		"application/json",
		strings.NewReader(string(body)),
	)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("europa returned %d", resp.StatusCode)
	}

	return nil
}

func (m model) waitForFile(nfsPath string) error {
	deadline := time.Now().Add(30 * time.Minute)
	lastSize := int64(-1)

	for time.Now().Before(deadline) {
		select {
		case <-m.ctx.Done():
			return m.ctx.Err()
		default:
		}

		fi, err := os.Stat(nfsPath)
		if err == nil && fi.Size() > 0 {
			if fi.Size() == lastSize {
				return nil // File is complete
			}
			lastSize = fi.Size()
		}

		pct := 0.1 + (time.Since(deadline.Add(-30*time.Minute)).Minutes() / 30 * 0.8)
		if pct > 0.99 {
			pct = 0.99
		}

		time.Sleep(2 * time.Second)
	}

	return fmt.Errorf("download timeout after 30 minutes")
}

func (m model) launchEmulator(romPath string) error {
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
