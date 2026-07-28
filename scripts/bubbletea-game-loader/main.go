package main

import (
	"archive/zip"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
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

		_, err = io.Copy(outFile, rc)
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

// Minerva_Myrient torrent — community backup of Myrient archive
// Contains all No-Intro, Redump, and other ROM collections
const minervaMagnet = "magnet:?xt=urn:btih:c1358e4763f8a5935109412b7d0db46ce9af238e&dn=Minerva_Myrient&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce&tr=udp%3A%2F%2F9.rarbg.com%3A2810%2Fannounce&tr=udp%3A%2F%2Ftracker.openbittorrent.com%3A6969%2Fannounce&tr=http%3A%2F%2Ftracker.openbittorrent.com%3A80%2Fannounce&tr=http%3A%2F%2F95.107.48.115%3A80%2Fannounce&tr=http%3A%2F%2Fopen.acgnxtracker.com%3A80%2Fannounce&tr=http%3A%2F%2Ft.acg.rip%3A6699%2Fannounce&tr=http%3A%2F%2Ft.nyaatracker.com%3A80%2Fannounce&tr=http%3A%2F%2Ftracker.bt4g.com%3A2095%2Fannounce&tr=http%3A%2F%2Ftracker.files.fm%3A6969%2Fannounce&tr=http%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce&tr=http%3A%2F%2Fvps02.net.orel.ru%3A80%2Fannounce&tr=https%3A%2F%2F1337.abcvg.info%3A443%2Fannounce&tr=https%3A%2F%2Fopentracker.i2p.rocks%3A443%2Fannounce&tr=https%3A%2F%2Ftracker.nanoha.org%3A443%2Fannounce&tr=https%3A%2F%2Ftracker.sloppyta.co%3A443%2Fannounce&tr=udp%3A%2F%2F208.83.20.20%3A6969%2Fannounce&tr=udp%3A%2F%2F37.235.174.46%3A2710%2Fannounce&tr=udp%3A%2F%2F75.127.14.224%3A2710%2Fannounce&tr=udp%3A%2F%2Fexodus.desync.com%3A6969%2Fannounce&tr=udp%3A%2F%2Fexplodie.org%3A6969%2Fannounce&tr=udp%3A%2F%2Ffe.dealclub.de%3A6969%2Fannounce&tr=udp%3A%2F%2Fipv4.tracker.harry.lu%3A80%2Fannounce&tr=udp%3A%2F%2Fmovies.zsw.ca%3A6969%2Fannounce&tr=udp%3A%2F%2Fopen.demonii.com%3A1337%2Fannounce&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce&tr=udp%3A%2F%2Fopentracker.i2p.rocks%3A6969%2Fannounce&tr=udp%3A%2F%2Fp4p.arenabg.com%3A1337%2Fannounce&tr=udp%3A%2F%2Fpublic.tracker.vraphim.com%3A6969%2Fannounce&tr=udp%3A%2F%2Fretracker.lanta-net.ru%3A2710%2Fannounce&tr=udp%3A%2F%2Ftracker.0x.tf%3A6969%2Fannounce&tr=udp%3A%2F%2Ftracker.dler.org%3A6969%2Fannounce&tr=udp%3A%2F%2Ftracker.filemail.com%3A6969%2Fannounce&tr=udp%3A%2F%2Ftracker.moeking.me%3A6969%2Fannounce&tr=udp%3A%2F%2Ftracker.pomf.se%3A80%2Fannounce&tr=udp%3A%2F%2Ftracker.swateam.org.uk%3A2710%2Fannounce&tr=udp%3A%2F%2Ftracker.tiny-vps.com%3A6969%2Fannounce&tr=udp%3A%2F%2Ftracker.torrent.eu.org%3A451%2Fannounce&tr=https%3A%2F%2Ftracker1.ctix.cn%3A443%2Fannounce&tr=https%3A%2F%2Ftracker.loligirl.cn%3A443%2Fannounce&tr=udp%3A%2F%2Ftracker-udp.gbitt.info%3A80%2Fannounce&tr=https%3A%2F%2Ftracker.gbitt.info%3A443%2Fannounce&tr=http%3A%2F%2Ftracker.gbitt.info%3A80%2Fannounce&tr=udp%3A%2F%2Ftracker.therarbg.to%3A6969%2Fannounce&tr=udp%3A%2F%2Ftracker.therarbg.com%3A6969%2Fannounce&tr=udp%3A%2F%2Fopentracker.io%3A6969%2Fannounce&tr=udp%3A%2F%2Fnew-line.net%3A6969%2Fannounce&tr=udp%3A%2F%2Fmoonburrow.club%3A6969%2Fannounce&tr=udp%3A%2F%2Fepider.me%3A6969%2Fannounce&tr=udp%3A%2F%2Fbt1.archive.org%3A6969%2Fannounce&tr=udp%3A%2F%2Fbt.ktrackers.com%3A6666%2Fannounce"

// Torrent download directory (shared between all kiosks via NFS or local cache)
const torrentDir = "/var/cache/pegasus-torrents"

func (m model) download() error {
	// Parse collection/game from src (e.g., "1g1r-nointro-nes/Super Mario Bros.nes")
	parts := strings.SplitN(m.src, "/", 2)
	if len(parts) != 2 {
		return fmt.Errorf("invalid src format: %s", m.src)
	}
	collection := parts[0]
	gameFile := parts[1]

	// Map collection to Myrient archive path
	archivePath := m.collectionToMyrientPath(collection, gameFile)
	if archivePath == "" {
		return fmt.Errorf("unknown collection: %s", collection)
	}

	// Download via Minerva_Myrient torrent
	return m.downloadViaMinervaTorrent(archivePath)
}

func (m model) downloadViaMinervaTorrent(archivePath string) error {
	// archivePath is like "No-Intro/Nintendo - NES/Super Mario Bros..nes"
	// We need to extract it from the Minerva_Myrient torrent

	m.sendProgress(0, "", "", "Starting torrent download for Minerva_Myrient...")

	// Ensure torrent directory exists
	if err := os.MkdirAll(torrentDir, 0755); err != nil {
		return fmt.Errorf("mkdir torrent dir: %w", err)
	}

	// Start/resume torrent download using transmission-cli
	torrentPath := filepath.Join(torrentDir, "Minerva_Myrient")
	if err := m.startTorrentDownload(minervaMagnet, torrentDir); err != nil {
		return fmt.Errorf("start torrent: %w", err)
	}

	// Poll for the specific file we need
	gamePathInTorrent := filepath.Join(torrentPath, strings.ReplaceAll(archivePath, "/", string(filepath.Separator)))
	if err := m.waitForFile(gamePathInTorrent, 5*time.Minute); err != nil {
		return fmt.Errorf("download timeout: %w", err)
	}

	// Copy from torrent to destination
	if err := m.copyFile(gamePathInTorrent, m.dst); err != nil {
		return fmt.Errorf("copy file: %w", err)
	}

	return nil
}

func (m model) startTorrentDownload(magnet string, downloadDir string) error {
	// Check if transmission-daemon is running; if not, start it
	_, err := os.Stat("/var/run/transmission/transmission.sock")
	if err != nil {
		m.sendProgress(0, "", "", "Starting transmission daemon...")
		cmd := exec.CommandContext(m.ctx, "transmission-daemon", "--download-dir", downloadDir)
		if err := cmd.Start(); err != nil {
			return fmt.Errorf("start transmission: %w", err)
		}
		time.Sleep(2 * time.Second)
	}

	// Add torrent via transmission-remote
	m.sendProgress(0, "", "", "Adding Minerva_Myrient torrent...")
	cmd := exec.CommandContext(m.ctx, "transmission-remote", "--add", magnet)
	if output, err := cmd.CombinedOutput(); err != nil {
		// It's okay if already added
		if !strings.Contains(string(output), "already in the transmission queue") {
			return fmt.Errorf("add torrent: %w", err)
		}
	}

	return nil
}

func (m model) waitForFile(filePath string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	lastSize := int64(-1)
	stuckCount := 0

	for {
		select {
		case <-m.ctx.Done():
			return m.ctx.Err()
		default:
		}

		// Check if file exists
		fi, err := os.Stat(filePath)
		if err == nil && !fi.IsDir() {
			// File exists and is complete (size stable for 2 checks)
			if fi.Size() == lastSize {
				m.sendProgress(1.0, "", "", "Download complete!")
				return nil
			}
			lastSize = fi.Size()
			percent := 0.1 // Rough estimate since we can't see full torrent progress easily
			m.sendProgress(percent, "", "", fmt.Sprintf("Downloading %s", formatBytes(fi.Size())))
			stuckCount = 0
		} else if time.Now().After(deadline) {
			return fmt.Errorf("file not downloaded within timeout: %s", filePath)
		} else {
			m.sendProgress(0, "", "", "Waiting for torrent download...")
			stuckCount++
		}

		time.Sleep(1 * time.Second)
	}
}

func (m model) copyFile(src, dst string) error {
	srcFile, err := os.Open(src)
	if err != nil {
		return err
	}
	defer srcFile.Close()

	dstFile, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer dstFile.Close()

	_, err = io.Copy(dstFile, srcFile)
	return err
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