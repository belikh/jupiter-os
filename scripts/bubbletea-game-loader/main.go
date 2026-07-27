package main

import (
	"archive/zip"
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/bubbles/progress"
	"github.com/charmbracelet/lipgloss"
)

type operation string

const (
	opExtract operation = "extract"
	opDownload operation = "download"
)

type tickMsg time.Time
type progressMsg struct {
	percent float64
	speed   string
	eta     string
	status  string
}
type doneMsg struct{ err error }
type cancelMsg struct{}

type model struct {
	title      string
	operation  operation
	src        string
	dst        string
	nfsMount   string
	progress   progress.Model
	percent    float64
	status     string
	speed      string
	eta        string
	err        error
	cancelled  bool
	done       bool
	ctx        context.Context
	cancelFunc context.CancelFunc
	wg         sync.WaitGroup
}

var (
	titleStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("#FAFAFA")).
			Background(lipgloss.Color("#1E1E2E")).
			Padding(0, 1).
			MarginBottom(1)

	progressStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#F5E0DC")).
			MarginLeft(2)

	statusStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#A6ADC8")).
			MarginLeft(2)

	speedStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#F9E2AF")).
			MarginLeft(2)

	etaStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#89B4FA")).
			MarginLeft(2)

	cancelStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#F38BA8")).
			MarginLeft(2)

	barStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#89B4FA"))

	barEmptyStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#313244"))
)

func initialModel(title string, op operation, src, dst, nfsMount string) model {
	ctx, cancel := context.WithCancel(context.Background())
	m := model{
		title:      title,
		operation:  op,
		src:        src,
		dst:        dst,
		nfsMount:   nfsMount,
		progress:   progress.New(progress.WithDefaultGradient()),
		ctx:        ctx,
		cancelFunc: cancel,
		status:     "Initializing...",
	}
	m.progress.Width = 60
	m.progress.ShowPercentage = true
	return m
}

func (m model) Init() tea.Cmd {
	return tea.Batch(
		m.doWork(),
		tickCmd(),
	)
}

func tickCmd() tea.Cmd {
	return tea.Tick(time.Millisecond*100, func(t time.Time) tea.Msg {
		return tickMsg(t)
	})
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		if msg.Type == tea.KeyRunes && (string(msg.Runes) == "q" || string(msg.Runes) == "Q") {
			if !m.done && !m.cancelled {
				m.cancelled = true
				m.status = "Cancelling..."
				m.cancelFunc()
				return m, tea.Batch(
					m.cleanupPartial(),
					tickCmd(),
				)
			}
		}
		if msg.Type == tea.KeyCtrlC {
			if !m.done && !m.cancelled {
				m.cancelled = true
				m.status = "Cancelling..."
				m.cancelFunc()
				return m, tea.Batch(
					m.cleanupPartial(),
					tickCmd(),
				)
			}
		}

	case tickMsg:
		if !m.done && !m.cancelled {
			return m, tickCmd()
		}

	case progressMsg:
		m.percent = msg.percent
		m.speed = msg.speed
		m.eta = msg.eta
		m.status = msg.status
		return m, tickCmd()

	case doneMsg:
		m.done = true
		m.err = msg.err
		if msg.err != nil {
			m.status = fmt.Sprintf("Error: %v", msg.err)
		} else {
			m.status = "Complete!"
			m.percent = 1.0
		}
		return m, tea.Quit

	case cancelMsg:
		m.done = true
		m.cancelled = true
		return m, tea.Quit
	}

	return m, nil
}

func (m model) View() string {
	if m.cancelled {
		return titleStyle.Render(fmt.Sprintf("🎮 Loading: %s", m.title)) + "\n\n" +
			cancelStyle.Render("Cancelled. Cleaning up...") + "\n"
	}

	var b strings.Builder
	b.WriteString(titleStyle.Render(fmt.Sprintf("🎮 Loading: %s", m.title)))
	b.WriteString("\n\n")

	bar := m.progress.ViewAs(m.percent)
	b.WriteString(progressStyle.Render(bar))
	b.WriteString("\n\n")

	if m.operation == opDownload && m.speed != "" {
		b.WriteString(speedStyle.Render(fmt.Sprintf("Downloading  •  %s  •  ETA: %s", m.speed, m.eta)))
		b.WriteString("\n")
	} else if m.operation == opExtract {
		b.WriteString(statusStyle.Render(fmt.Sprintf("Extracting  •  %s", m.status)))
		b.WriteString("\n")
	} else {
		b.WriteString(statusStyle.Render(m.status))
		b.WriteString("\n")
	}

	b.WriteString("\n")
	b.WriteString(cancelStyle.Render("Press 'q' to cancel"))
	b.WriteString("\n")

	return b.String()
}

func (m model) doWork() tea.Cmd {
	return func() tea.Msg {
		var err error
		if m.operation == opExtract {
			err = m.extract()
		} else {
			err = m.download()
		}
		return doneMsg{err: err}
	}
}

func (m model) extract() error {
	zipPath := filepath.Join(m.nfsMount, "retro/games", m.src)
	if _, err := os.Stat(zipPath); os.IsNotExist(err) {
		return fmt.Errorf("source zip not found: %s", zipPath)
	}

	r, err := zip.OpenReader(zipPath)
	if err != nil {
		return fmt.Errorf("open zip: %w", err)
	}
	defer r.Close()

	totalFiles := len(r.File)
	if totalFiles == 0 {
		return errors.New("zip archive is empty")
	}

	if err := os.MkdirAll(m.dst, 0755); err != nil {
		return fmt.Errorf("mkdir: %w", err)
	}

	extracted := 0
	for _, f := range r.File {
		select {
		case <-m.ctx.Done():
			return m.ctx.Err()
		default:
		}

		targetPath := filepath.Join(m.dst, f.Name)

		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(targetPath, f.Mode()); err != nil {
				return fmt.Errorf("mkdir %s: %w", targetPath, err)
			}
			continue
		}

		if err := os.MkdirAll(filepath.Dir(targetPath), 0755); err != nil {
			return fmt.Errorf("mkdir parent: %w", err)
		}

		rc, err := f.Open()
		if err != nil {
			return fmt.Errorf("open entry %s: %w", f.Name, err)
		}

		outFile, err := os.OpenFile(targetPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, f.Mode())
		if err != nil {
			rc.Close()
			return fmt.Errorf("create %s: %w", targetPath, err)
		}

		written, err := io.Copy(outFile, rc)
		rc.Close()
		outFile.Close()
		if err != nil {
			return fmt.Errorf("write %s: %w", targetPath, err)
		}

		extracted++
		percent := float64(extracted) / float64(totalFiles)
		m.sendProgress(percent, "", "", fmt.Sprintf("Extracting %d/%d files", extracted, totalFiles))
	}

	return nil
}

var myrientMirrors = []string{
	"https://myrient.erista.me/files",
	"https://archive.org/download",
	"https://cdn-archive.org/download",
	"https://ia800508.us.archive.org/download",
	"https://ia600508.us.archive.org/download",
}

// Torrent/magnet fallback for Minerva Archive (Myrient community backup)
var torrentTrackers = []string{
	"udp://tracker.opentrackr.org:1337/announce",
	"udp://tracker.openbittorrent.com:80/announce",
	"udp://tracker.torrent.eu.org:451/announce",
	"udp://tracker.bittor.pw:1337/announce",
	"https://tracker.files.fm:443/announce",
}

func (m model) download() error {
	// Parse collection/game from src (e.g., "1g1r-nointro-nes/Super Mario Bros.nes")
	parts := strings.SplitN(m.src, "/", 2)
	if len(parts) != 2 {
		return fmt.Errorf("invalid src format: %s", m.src)
	}
	collection := parts[0]
	gameFile := parts[1]

	// Map collection to Myrient path
	myrientPath := m.collectionToMyrientPath(collection, gameFile)
	if myrientPath == "" {
		return fmt.Errorf("unknown collection: %s", collection)
	}

	var lastErr error
	for _, mirror := range myrientMirrors {
		url := strings.TrimRight(mirror, "/") + "/" + myrientPath
		m.sendProgress(0, "", "", fmt.Sprintf("Trying mirror: %s", mirror))

		err := m.downloadFromURL(url)
		if err == nil {
			return nil
		}
		lastErr = err
		m.sendProgress(0, "", "", fmt.Sprintf("Mirror failed: %v, trying next...", err))
	}

	return fmt.Errorf("all mirrors failed: %w", lastErr)
}

func (m model) collectionToMyrientPath(collection, gameFile string) string {
	switch collection {
	case "1g1r-nointro-nes":
		return "No-Intro/Nintendo%20-%20Nintendo%20Entertainment%20System/" + urlPathEscape(gameFile)
	case "1g1r-nointro-snes":
		return "No-Intro/Nintendo%20-%20Super%20Nintendo%20Entertainment%20System/" + urlPathEscape(gameFile)
	case "1g1r-nointro-gb":
		return "No-Intro/Nintendo%20-%20Game%20Boy/" + urlPathEscape(gameFile)
	case "1g1r-nointro-gbc":
		return "No-Intro/Nintendo%20-%20Game%20Boy%20Color/" + urlPathEscape(gameFile)
	case "1g1r-nointro-gba":
		return "No-Intro/Nintendo%20-%20Game%20Boy%20Advance/" + urlPathEscape(gameFile)
	case "1g1r-nointro-n64":
		return "No-Intro/Nintendo%20-%20Nintendo%2064/" + urlPathEscape(gameFile)
	case "1g1r-nointro-ds":
		return "No-Intro/Nintendo%20-%20Nintendo%20DS/" + urlPathEscape(gameFile)
	case "1g1r-redump-ps1":
		return "Redump/Sony%20-%20PlayStation/" + urlPathEscape(gameFile)
	case "1g1r-redump-ps2":
		return "Redump/Sony%20-%20PlayStation%202/" + urlPathEscape(gameFile)
	case "1g1r-redump-psp":
		return "Redump/Sony%20-%20PlayStation%20Portable/" + urlPathEscape(gameFile)
	case "1g1r-redump-saturn":
		return "Redump/Sega%20-%20Saturn/" + urlPathEscape(gameFile)
	case "1g1r-redump-dreamcast":
		return "Redump/Sega%20-%20Dreamcast/" + urlPathEscape(gameFile)
	case "1g1r-redump-gamecube":
		return "Redump/Nintendo%20-%20GameCube%20-%20NKit%20RVZ%20%5Bzstd-19-128k%5D/" + urlPathEscape(gameFile)
	case "1g1r-redump-wii":
		return "Redump/Nintendo%20-%20Wii%20-%20NKit%20RVZ%20%5Bzstd-19-128k%5D/" + urlPathEscape(gameFile)
	case "1g1r-redump-xbox":
		return "Redump/Microsoft%20-%20Xbox/" + urlPathEscape(gameFile)
	default:
		return ""
	}
}

func urlPathEscape(s string) string {
	// Simple URL path escaping for common chars
	s = strings.ReplaceAll(s, " ", "%20")
	s = strings.ReplaceAll(s, "(", "%28")
	s = strings.ReplaceAll(s, ")", "%29")
	s = strings.ReplaceAll(s, "'", "%27")
	s = strings.ReplaceAll(s, "[", "%5B")
	s = strings.ReplaceAll(s, "]", "%5D")
	return s
}

func (m model) downloadFromURL(url string) error {
	req, err := http.NewRequestWithContext(m.ctx, "GET", url, nil)
	if err != nil {
		return err
	}

	// Resume support
	if fi, err := os.Stat(m.dst); err == nil {
		req.Header.Set("Range", fmt.Sprintf("bytes=%d-", fi.Size()))
	}

	client := &http.Client{Timeout: 0}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusPartialContent {
		return fmt.Errorf("HTTP %d: %s", resp.StatusCode, resp.Status)
	}

	totalSize := resp.ContentLength
	if resp.StatusCode == http.StatusPartialContent {
		if fi, err := os.Stat(m.dst); err == nil {
			totalSize += fi.Size()
		}
	}

	outFile, err := os.OpenFile(m.dst, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0644)
	if err != nil {
		return err
	}
	defer outFile.Close()

	var written int64
	if fi, err := os.Stat(m.dst); err == nil {
		written = fi.Size()
	}

	buf := make([]byte, 32*1024)
	startTime := time.Now()
	lastUpdate := startTime
	lastWritten := written

	for {
		select {
		case <-m.ctx.Done():
			return m.ctx.Err()
		default:
		}

		n, err := resp.Body.Read(buf)
		if n > 0 {
			if _, wErr := outFile.Write(buf[:n]); wErr != nil {
				return wErr
			}
			written += int64(n)

			now := time.Now()
			elapsed := now.Sub(startTime).Seconds()
			if elapsed > 0 && now.Sub(lastUpdate) > 200*time.Millisecond {
				speed := float64(written-lastWritten) / now.Sub(lastUpdate).Seconds()
				var speedStr, etaStr string
				if speed > 0 {
					speedStr = formatSpeed(speed)
					if totalSize > 0 {
						remaining := totalSize - written
						if remaining > 0 {
							eta := time.Duration(float64(remaining)/speed) * time.Second
							etaStr = eta.Round(time.Second).String()
						}
					}
				}
				percent := 0.0
				if totalSize > 0 {
					percent = float64(written) / float64(totalSize)
				}
				m.sendProgress(percent, speedStr, etaStr, fmt.Sprintf("Downloaded %s / %s", formatBytes(written), formatBytes(totalSize)))
				lastUpdate = now
				lastWritten = written
			}
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
	}

	return nil
}

func formatBytes(b int64) string {
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

func formatSpeed(bps float64) string {
	return fmt.Sprintf("%.1f %s/s", bps/1024/1024, "MB")
}

func (m model) sendProgress(percent float64, speed, eta, status string) {
	select {
	case <-m.ctx.Done():
		return
	default:
		tea.NewProgram(m).Send(progressMsg{
			percent: percent,
			speed:   speed,
			eta:     eta,
			status:  status,
		})
	}
}

func (m model) cleanupPartial() tea.Cmd {
	return func() tea.Msg {
		if m.operation == opDownload {
			os.Remove(m.dst)
		} else if m.operation == opExtract {
			os.RemoveAll(m.dst)
		}
		return cancelMsg{}
	}
}

func main() {
	if len(os.Args) < 9 {
		fmt.Fprintf(os.Stderr, "Usage: %s --src <src> --dst <dst> --operation <extract|download> --nfs-mount <path> --title <title>\n", os.Args[0])
		os.Exit(2)
	}

	var src, dst, opStr, nfsMount, title string
	for i := 1; i < len(os.Args); i += 2 {
		switch os.Args[i] {
		case "--src":
			src = os.Args[i+1]
		case "--dst":
			dst = os.Args[i+1]
		case "--operation":
			opStr = os.Args[i+1]
		case "--nfs-mount":
			nfsMount = os.Args[i+1]
		case "--title":
			title = os.Args[i+1]
		}
	}

	var op operation
	switch opStr {
	case "extract":
		op = opExtract
	case "download":
		op = opDownload
	default:
		fmt.Fprintf(os.Stderr, "Invalid operation: %s\n", opStr)
		os.Exit(2)
	}

	m := initialModel(title, op, src, dst, nfsMount)
	p := tea.NewProgram(m, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}