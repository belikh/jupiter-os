// Downloads UI (gauntlet P2): aria2 queue view + system-centric join.
//
// This file carries the piece RomM structurally cannot (ADR-0002
// criterion 2) and the P1 critic's named gap (download stage had no
// surface): a 2s-polled queue fragment (depth, per-download
// progress/speed, pause/resume/remove) plus the join AriaNg lacks —
// every catalogue system's download state against its verify state
// (downloading / queued / errored / verify pill from the DB), with the
// one-click acquire action (submit this system's staged torrent into
// incomingDir/<sys>, aria2-rpc.sh semantics via aria2.AcquireTorrentOptions).
//
// Degradation contract: an unreachable or unconfigured daemon renders a
// state chip ("aria2 unreachable" / "not configured"), never a 500 —
// the dashboard stays legible exactly when the operator needs it.
package web

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/aria2"
	"github.com/belikh/jupiter-os/pkgs/arcade-webapp/internal/store"
)

// dlPaths are the filesystem anchors the downloads feature needs beyond
// the RPC client: where per-system downloads land (attribution + dir
// routing) and where the staged .torrent files live.
type dlPaths struct {
	IncomingDir string
	TorrentDir  string
}

// Option configures optional Server features (download control is one).
type Option func(*Server)

// WithAria2 wires download control: an RPC client (nil = not configured)
// plus the incoming/torrent dir anchors.
func WithAria2(cl *aria2.Client, incomingDir, torrentDir string) Option {
	return func(s *Server) {
		s.a2 = cl
		s.dl = dlPaths{IncomingDir: incomingDir, TorrentDir: torrentDir}
	}
}

// downloadsConfigured reports whether the aria2 wiring exists at all.
func (s *Server) downloadsConfigured() bool {
	return s.a2 != nil && s.a2.Configured()
}

// ---- view models ----------------------------------------------------------

type queueRow struct {
	GID, Status, Name, Dir         string
	System                         string // catalogue attribution via dir; "" = not ours
	Pct                            int
	CompletedHuman                 string
	TotalHuman                     string
	SpeedHuman                     string
	ErrorMessage                   string
	CanPause, CanResume, CanRemove bool
}

type systemDL struct {
	Key, Collection, Bucket string
	// Download side (live, from the queue).
	Downloading bool // ≥1 active download
	Queued      bool // waiting/paused only
	Errored     bool // any errored download
	ActivePct   int  // aggregate progress while downloading
	GIDs        int
	// Verify side (last ingested igir report — P3's zero-unmatched
	// indicator, shared with the card wall via verifyStateChip).
	GameCount    int64
	VerifyState  string
	VerifyCounts store.VerifyResult
	// Acquire side.
	TorrentName string // catalogue basename
	TorrentOK   bool   // staged file present under torrentDir
}

type downloadsVM struct {
	Configured bool
	Reachable  bool
	Error      string // short, already-escaped-source text; "" when healthy
	Version    string
	Stat       aria2.GlobalStat
	Queue      []queueRow
	Throughput int64 // sum of active downloadSpeed
	// Partial marks a reachable daemon whose tell* batch failed in part
	// (mid-batch timeout, one 5xx): the queue below is incomplete, and
	// the fragment says so instead of rendering a silently short list.
	Partial bool
	// Hidden counts downloads the daemon knows (GlobalStat) but the
	// capped tell* fetches didn't return — rendered as a truncation
	// hint so entries never just vanish.
	HiddenWaiting int
	HiddenStopped int
	// System-centric join — the view AriaNg cannot express.
	Systems   []systemDL
	IdleCount int // catalogue systems with no download/torrent/verify signal
	Meta      pageMeta
	Now       time.Time
}

type downloadsSummaryVM struct {
	Configured bool
	Reachable  bool
	Active     int64
	Waiting    int64
	Errored    int
	Throughput int64
}

// Queue fetch caps: how many waiting/stopped entries one poll renders.
// Beyond them the fragment carries a truncation hint (the daemon's
// GlobalStat knows the true counts) — the queue view stays cheap on
// europa's 2-core budget while never hiding that it truncated.
const (
	maxWaitingShown = 100
	maxStoppedShown = 50
)

// fetchDownloads assembles the downloads view model: one bounded context
// for the whole RPC batch (a wedged daemon degrades the fragment after
// the query timeout, never hangs the poll chain), then the pure join
// against the store.
func (s *Server) fetchDownloads(ctx context.Context) downloadsVM {
	vm := downloadsVM{Configured: s.downloadsConfigured(), Now: time.Now()}
	vm.Meta = pageMeta{Title: "downloads", Sub: "download control", ActiveDloads: true}
	if !vm.Configured {
		vm.Meta.HealthLabel, vm.Meta.HealthClass = "not configured", "unknown"
		vm.Systems, vm.IdleCount = s.joinSystems(nil)
		return vm
	}

	ctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()

	var queue []aria2.Download
	v, err := s.a2.GetVersion(ctx)
	if err == nil {
		vm.Version = v.Version
		vm.Reachable = true
	}
	if gs, err := s.a2.GetGlobalStat(ctx); err == nil {
		vm.Stat = gs
		vm.Reachable = true
	} else {
		vm.Error = friendlyAria2Error(err)
	}
	if vm.Reachable {
		// The tell* batch: each call is best-effort. A failure marks the
		// queue PARTIAL (hint on the fragment) rather than unreachable —
		// the stat/version answers prove the daemon is up; a partial
		// render must not masquerade as the whole truth (ADV-P2-03a).
		if act, err := s.a2.TellActive(ctx); err == nil {
			queue = append(queue, act...)
			for _, d := range act {
				vm.Throughput += d.DownloadSpeed
			}
		} else {
			vm.Partial = true
		}
		if w, err := s.a2.TellWaiting(ctx, 0, maxWaitingShown); err == nil {
			queue = append(queue, w...)
			// Truncation hint vs GlobalStat's authoritative count
			// (ADV-P2-02) — only on a successful fetch, else the hint
			// would count failures as hidden entries.
			if extra := int(vm.Stat.NumWaiting) - len(w); extra > 0 {
				vm.HiddenWaiting = extra
			}
		} else {
			vm.Partial = true
		}
		if st, err := s.a2.TellStopped(ctx, 0, maxStoppedShown); err == nil {
			queue = append(queue, st...)
			if extra := int(vm.Stat.NumStopped) - len(st); extra > 0 {
				vm.HiddenStopped = extra
			}
		} else {
			vm.Partial = true
		}
	}

	// Contextual topbar chip: the daemon's own health.
	switch {
	case !vm.Reachable:
		vm.Meta.HealthLabel, vm.Meta.HealthClass = "aria2 unreachable", "stale"
	case vm.Version != "":
		vm.Meta.HealthLabel, vm.Meta.HealthClass = "aria2 "+vm.Version, "ok"
	default:
		vm.Meta.HealthLabel, vm.Meta.HealthClass = "aria2 up", "ok"
	}

	vm.Queue = s.queueRows(queue)
	vm.Systems, vm.IdleCount = s.joinSystems(queue)
	return vm
}

// friendlyAria2Error renders an operator-facing one-liner. Transport
// failures are the "aria2 unreachable" state; JSON-RPC errors keep the
// daemon's message (it never contains the token).
func friendlyAria2Error(err error) string {
	var te *aria2.TransportError
	if errors.As(err, &te) {
		return "aria2 unreachable"
	}
	var re *aria2.RPCError
	if errors.As(err, &re) {
		return "aria2: " + re.Message
	}
	return "aria2 error"
}

// queueRows maps wire downloads to render rows with button visibility:
// pause for active/waiting, resume for paused, remove for everything
// still in the daemon's lists.
func (s *Server) queueRows(queue []aria2.Download) []queueRow {
	rows := make([]queueRow, 0, len(queue))
	for _, d := range queue {
		row := queueRow{
			GID:            d.GID,
			Status:         d.Status,
			Name:           d.Name(),
			Dir:            d.Dir,
			System:         s.systemForDir(d.Dir),
			Pct:            d.ProgressPct(),
			CompletedHuman: HumanBytes(d.CompletedLength),
			TotalHuman:     HumanBytes(d.TotalLength),
			SpeedHuman:     HumanBytes(d.DownloadSpeed) + "/s",
			ErrorMessage:   d.ErrorMessage,
			CanPause:       d.Status == "active" || d.Status == "waiting",
			CanResume:      d.Status == "paused",
			CanRemove:      d.Status != "removed",
		}
		if d.Status != "active" {
			row.SpeedHuman = ""
		}
		rows = append(rows, row)
	}
	return rows
}

// systemForDir attributes a download to a catalogue system via its dir:
// downloads we submitted land exactly in <incomingDir>/<sys>. Anything
// else (the daemon is fleet-shared — e.g. /tank/downloads) is not ours.
func (s *Server) systemForDir(dir string) string {
	if s.dl.IncomingDir == "" || dir == "" {
		return ""
	}
	rel, err := filepath.Rel(s.dl.IncomingDir, filepath.Clean(dir))
	if err != nil || rel == "." || strings.HasPrefix(rel, "..") || filepath.Dir(rel) != "." {
		return ""
	}
	return rel
}

// joinSystems is the P2 centerpiece: per catalogue system, its live
// download state (active/waiting/paused/errored via dir attribution)
// joined against its verify state (what the DB knows — P1 semantics,
// 'unknown' until P3 ingests igir reports) and its acquire availability
// (staged torrent present). Systems with no signal at all collapse into
// IdleCount, mirroring the P1 card wall's empty-systems footer.
func (s *Server) joinSystems(queue []aria2.Download) ([]systemDL, int) {
	summary, err := s.st.SystemSummary()
	if err != nil {
		log.Printf("web: downloads join: %v", err)
		return nil, 0
	}

	// Aggregate queue state per attributed system.
	type dlState struct {
		active, queued, errored int
		pctNum, pctDen          int64
	}
	bySys := map[string]*dlState{}
	for _, d := range queue {
		sys := s.systemForDir(d.Dir)
		if sys == "" {
			continue
		}
		st, ok := bySys[sys]
		if !ok {
			st = &dlState{}
			bySys[sys] = st
		}
		switch d.Status {
		case "active":
			st.active++
			st.pctNum += d.CompletedLength
			st.pctDen += d.TotalLength
		case "waiting", "paused":
			st.queued++
		case "error":
			st.errored++
		}
	}

	var out []systemDL
	idle := 0
	for _, sys := range summary {
		if sys.Source == store.SourceExo {
			continue // P8: browse/curation-only, no download surface
		}
		row := systemDL{
			Key:          sys.Key,
			Collection:   sys.Collection,
			Bucket:       sys.Bucket,
			GameCount:    sys.GameCount,
			VerifyState:  classifyVerify(sys.Verify, sys.VerifyPresent),
			VerifyCounts: sys.Verify,
		}
		if st := bySys[sys.Key]; st != nil {
			row.GIDs = st.active + st.queued + st.errored
			row.Downloading = st.active > 0
			row.Queued = st.queued > 0
			row.Errored = st.errored > 0
			if st.pctDen > 0 {
				row.ActivePct = int(st.pctNum * 100 / st.pctDen)
				if row.ActivePct > 100 {
					row.ActivePct = 100
				}
			}
		}
		if sys.Torrent != "" {
			row.TorrentName = sys.Torrent
			if s.dl.TorrentDir != "" {
				if _, err := os.Stat(filepath.Join(s.dl.TorrentDir, sys.Torrent)); err == nil {
					row.TorrentOK = true
				}
			}
		}
		if !row.Downloading && !row.Queued && !row.Errored && !row.TorrentOK &&
			sys.GameCount == 0 && sys.DATDate == "" {
			idle++
			continue
		}
		out = append(out, row)
	}
	return out, idle
}

// ---- handlers ---------------------------------------------------------------

func (s *Server) handleDownloads(w http.ResponseWriter, r *http.Request) {
	vm := s.fetchDownloads(r.Context())
	s.render(w, http.StatusOK, "layout-downloads", vm)
}

func (s *Server) handlePartialDownloads(w http.ResponseWriter, r *http.Request) {
	vm := s.fetchDownloads(r.Context())
	s.render(w, http.StatusOK, "partial-downloads", vm)
}

func (s *Server) handlePartialDownloadsSummary(w http.ResponseWriter, r *http.Request) {
	vm := s.fetchDownloads(r.Context())
	sum := downloadsSummaryVM{
		Configured: vm.Configured,
		Reachable:  vm.Reachable,
		Active:     vm.Stat.NumActive,
		Waiting:    vm.Stat.NumWaiting,
		Throughput: vm.Throughput,
	}
	for _, q := range vm.Queue {
		if q.Status == "error" {
			sum.Errored++
		}
	}
	s.render(w, http.StatusOK, "partial-downloads-summary", sum)
}

// hxRequestOK is the CSRF posture for every mutating endpoint. htmx
// natively sends `HX-Request: true` on every request it makes; plain
// cross-site HTML form posts cannot send either that header or any
// custom one without a CORS preflight, so header presence is the
// proportionate defense for a LAN-only, cookie-less service (closes the
// ADV-P1-07 carry-over). The custom X-HX-Request stays accepted for
// scripts and the historical tests — but the native header is the one
// browsers actually carry. (The original P2 implementation checked ONLY
// X-HX-Request on the belief that htmx sends it — it never did, so every
// browser-originated mutation 403'd from day one; only header-toting
// curls ever worked.)
func hxRequestOK(r *http.Request) bool {
	return r.Header.Get("HX-Request") != "" || r.Header.Get("X-HX-Request") != ""
}

// handleAcquire submits one system's staged torrent to the daemon — the
// webapp's replacement for the jupiter-rom-acquire oneshot's per-system
// branch: dir routes into incomingDir/<sys>, resume semantics identical
// to aria2-rpc.sh submit-torrent (AcquireTorrentOptions). Recorded as an
// 'acquire' run for the dashboard's audit trail.
func (s *Server) handleAcquire(w http.ResponseWriter, r *http.Request) {
	if !hxRequestOK(r) {
		http.Error(w, "htmx requests only", http.StatusForbidden)
		return
	}
	if !s.downloadsConfigured() {
		// 503, consistent with dlControl's not-configured answer
		// (ADV-P2-03b): the endpoint cannot do its job in this state.
		http.Error(w, "download control not configured", http.StatusServiceUnavailable)
		return
	}
	sys := r.PathValue("system")

	vmErr := s.acquire(r.Context(), sys)

	vm := s.fetchDownloads(r.Context())
	if vmErr != "" {
		// Surface the failure on the fragment (htmx swaps it in) —
		// the queue itself may still be perfectly healthy.
		vm.Error = vmErr
	}
	s.render(w, http.StatusAccepted, "partial-downloads", vm)
}

// acquire does the work of one submission and returns "" on success or
// a short operator-facing error string.
func (s *Server) acquire(ctx context.Context, sys string) string {
	summary, err := s.st.SystemSummary()
	if err != nil {
		log.Printf("web: acquire %s: %v", sys, err)
		return "system lookup failed"
	}
	var row *store.SystemSummary
	for i := range summary {
		if summary[i].Key == sys {
			row = &summary[i]
			break
		}
	}
	if row == nil {
		return "unknown system " + sys
	}
	if row.Torrent == "" {
		return sys + " has no torrent in the catalogue"
	}
	torrentPath := filepath.Join(s.dl.TorrentDir, row.Torrent)
	if _, err := os.Stat(torrentPath); err != nil {
		return "torrent not staged: " + row.Torrent
	}

	runID, _ := s.st.StartRun("acquire")
	gid, err := s.a2.AddTorrent(ctx, torrentPath, aria2.AcquireTorrentOptions(s.dl.IncomingDir, sys))
	if err != nil {
		// Code 12 "is already registered" after (say) an ambiguous
		// addTorrent timeout+retry means the submission DID land — the
		// download exists under this exact dir. Success-with-note, not
		// an error (ADV-P2-04); same semantics the acquire oneshot's
		// rerun path relies on.
		if aria2.IsAlreadyRegistered(err) {
			detail, _ := json.Marshal(struct {
				System string `json:"system"`
				Note   string `json:"note"`
			}{System: sys, Note: "already registered"})
			_ = s.st.FinishRun(runID, "ok", string(detail))
			log.Printf("web: acquire %s: already registered (idempotent rerun)", sys)
			return ""
		}
		log.Printf("web: acquire %s: %v", sys, err)
		_ = s.st.FinishRun(runID, "error", sys+": "+err.Error())
		return "submit failed: " + friendlyAria2Error(err)
	}
	detail, _ := json.Marshal(struct {
		System string `json:"system"`
		GID    string `json:"gid"`
	}{System: sys, GID: gid})
	_ = s.st.FinishRun(runID, "ok", string(detail))
	log.Printf("web: acquire %s: submitted gid=%s", sys, gid)
	return ""
}

// dlControl runs pause/resume/remove and answers with the refreshed
// queue fragment. GIDs come from our own rendered rows; the daemon is
// the authority on their validity (bad gid → an aria2 error surfaced on
// the fragment).
func (s *Server) dlControl(action string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !hxRequestOK(r) {
			http.Error(w, "htmx requests only", http.StatusForbidden)
			return
		}
		gid := r.PathValue("gid")
		if !s.downloadsConfigured() {
			http.Error(w, "download control not configured", http.StatusServiceUnavailable)
			return
		}

		var err error
		switch action {
		case "pause":
			err = s.a2.Pause(r.Context(), gid)
		case "resume":
			err = s.a2.Unpause(r.Context(), gid)
		case "remove":
			err = s.a2.Remove(r.Context(), gid)
		}
		vm := s.fetchDownloads(r.Context())
		if err != nil {
			log.Printf("web: %s %s: %v", action, gid, err)
			vm.Error = action + " failed: " + friendlyAria2Error(err)
		}
		s.render(w, http.StatusOK, "partial-downloads", vm)
	}
}

// ---- torrent staging (P2 critic's named gap, landed with P3) ---------------
//
// The acquire column used to dead-end when a system's torrent was
// missing from torrentDir. Two affordances close it, both minimal and
// real:
//
//   - POST /systems/{sys}/stage-torrent (multipart file upload): the
//     operator drops in the .torrent they have; it is stored under
//     torrentDir with the CATALOGUE-expected basename so the regular
//     acquire action (and rom-acquire) finds it where the catalogue says
//     it lives;
//   - POST /systems/{sys}/stage-uri (magnet:/http(s): URI): submitted
//     straight to the daemon with the acquire option shape (dir routing
//     into incomingDir/<sys>, seed-time 0, overwrite, integrity-aware
//     resume) — the "queue it now" path.
//
// Both are htmx-only (CSRF), validate the system against the catalogue,
// and cap input size.

// maxTorrentUpload caps the uploaded .torrent at 64 MiB — generous
// against the largest Minerva optical sets (PS2-era torrents reach tens
// of MB) while keeping a stray upload from filling scratch.
const maxTorrentUpload = 64 << 20

// maxStageURIBytes caps the pasted URI field length.
const maxStageURIBytes = 8192

// handleStageTorrent stores an uploaded .torrent under torrentDir with
// the catalogue-expected name.
func (s *Server) handleStageTorrent(w http.ResponseWriter, r *http.Request) {
	if !hxRequestOK(r) {
		http.Error(w, "htmx requests only", http.StatusForbidden)
		return
	}
	sys := r.PathValue("system")
	torrentName, code, msg := s.stageTarget(sys)
	if code != 0 {
		http.Error(w, msg, code)
		return
	}

	// Size cap BEFORE parsing: MaxBytesReader guards the whole body.
	r.Body = http.MaxBytesReader(w, r.Body, maxTorrentUpload+(1<<20))
	if err := r.ParseMultipartForm(1 << 20); err != nil {
		http.Error(w, "upload too large or malformed (64 MiB cap)", http.StatusRequestEntityTooLarge)
		return
	}
	file, hdr, err := r.FormFile("torrent")
	if err != nil {
		http.Error(w, "missing 'torrent' file field", http.StatusBadRequest)
		return
	}
	defer file.Close() //nolint:errcheck // read-only
	if !strings.EqualFold(filepath.Ext(hdr.Filename), ".torrent") {
		http.Error(w, "not a .torrent file: "+filepath.Base(hdr.Filename), http.StatusBadRequest)
		return
	}

	dst := filepath.Join(s.dl.TorrentDir, torrentName)
	if err := os.MkdirAll(s.dl.TorrentDir, 0o755); err != nil {
		http.Error(w, "torrentDir unavailable", http.StatusInternalServerError)
		return
	}
	b, err := io.ReadAll(file)
	if err != nil {
		http.Error(w, "reading upload failed", http.StatusBadRequest)
		return
	}
	if len(b) == 0 {
		http.Error(w, "empty torrent file", http.StatusBadRequest)
		return
	}
	// ADV-P3-04: O_CREATE|O_EXCL|O_NOFOLLOW — whatever already sits at
	// torrentDir/<catalogue-name> (a regular file OR a pre-planted
	// symlink) fails loudly instead of being overwritten/followed;
	// os.WriteFile would write straight through a symlink. Not remotely
	// reachable today (root-owned dir, catalogue-whitelisted names) —
	// the flag pair makes it structurally impossible anyway.
	// (syscall.O_NOFOLLOW: not in the portable os set — the webapp is
	// Linux-only, every consumer is a NixOS host.)
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o644)
	if err != nil {
		if errors.Is(err, os.ErrExist) {
			http.Error(w, "torrent already staged as "+torrentName+" — delete it first (refusing to overwrite)", http.StatusConflict)
			return
		}
		http.Error(w, "storing torrent failed", http.StatusInternalServerError)
		return
	}
	if _, werr := out.Write(b); werr != nil {
		out.Close() //nolint:errcheck // error path
		http.Error(w, "storing torrent failed", http.StatusInternalServerError)
		return
	}
	if cerr := out.Close(); cerr != nil {
		http.Error(w, "storing torrent failed", http.StatusInternalServerError)
		return
	}

	runID, _ := s.st.StartRun("stage-torrent")
	detail, _ := json.Marshal(struct {
		System string `json:"system"`
		Bytes  int    `json:"bytes"`
		Stored string `json:"stored"`
	}{System: sys, Bytes: len(b), Stored: torrentName})
	_ = s.st.FinishRun(runID, "ok", string(detail))
	log.Printf("web: staged torrent for %s: %d bytes as %s", sys, len(b), torrentName)

	vm := s.fetchDownloads(r.Context())
	s.render(w, http.StatusOK, "partial-downloads", vm)
}

// handleStageURI submits a magnet:/http(s): URI for the system straight
// to the daemon (addUri with the acquire option shape).
func (s *Server) handleStageURI(w http.ResponseWriter, r *http.Request) {
	if !hxRequestOK(r) {
		http.Error(w, "htmx requests only", http.StatusForbidden)
		return
	}
	if !s.downloadsConfigured() {
		http.Error(w, "download control not configured", http.StatusServiceUnavailable)
		return
	}
	sys := r.PathValue("system")
	if _, code, msg := s.stageTarget(sys); code != 0 {
		http.Error(w, msg, code)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "malformed form", http.StatusBadRequest)
		return
	}
	uri := strings.TrimSpace(r.PostFormValue("uri"))
	if len(uri) > maxStageURIBytes {
		http.Error(w, "URI too long", http.StatusRequestEntityTooLarge)
		return
	}
	u, err := url.Parse(uri)
	if err != nil || (u.Scheme != "magnet" && u.Scheme != "http" && u.Scheme != "https") || (u.Scheme != "magnet" && u.Host == "") {
		http.Error(w, "URI must be a magnet: link or an http(s) URL", http.StatusBadRequest)
		return
	}

	runID, _ := s.st.StartRun("acquire")
	gid, err := s.a2.AddURI(r.Context(), []string{uri}, aria2.AcquireTorrentOptions(s.dl.IncomingDir, sys))
	if err != nil {
		if aria2.IsAlreadyRegistered(err) {
			detail, _ := json.Marshal(struct {
				System string `json:"system"`
				Note   string `json:"note"`
			}{System: sys, Note: "uri already registered"})
			_ = s.st.FinishRun(runID, "ok", string(detail))
		} else {
			log.Printf("web: stage-uri %s: %v", sys, err)
			_ = s.st.FinishRun(runID, "error", sys+": "+err.Error())
			vm := s.fetchDownloads(r.Context())
			vm.Error = "submit failed: " + friendlyAria2Error(err)
			s.render(w, http.StatusOK, "partial-downloads", vm)
			return
		}
	} else {
		detail, _ := json.Marshal(struct {
			System string `json:"system"`
			GID    string `json:"gid"`
			Via    string `json:"via"`
		}{System: sys, GID: gid, Via: "uri"})
		_ = s.st.FinishRun(runID, "ok", string(detail))
		log.Printf("web: staged URI for %s: gid=%s", sys, gid)
	}

	vm := s.fetchDownloads(r.Context())
	s.render(w, http.StatusOK, "partial-downloads", vm)
}

// stageTarget validates a staging target system and returns the
// catalogue-expected torrent basename (0 status = valid).
func (s *Server) stageTarget(sys string) (name string, code int, msg string) {
	systems, err := s.st.Systems()
	if err != nil {
		return "", http.StatusInternalServerError, "system lookup failed"
	}
	for _, row := range systems {
		if row.Key == sys {
			// P8: eXo curated collections are browse/curation-only — no
			// torrents exist for them and none may be staged.
			if row.Source == store.SourceExo {
				return "", http.StatusBadRequest, sys + " is an eXo curated collection: download control does not apply"
			}
			if row.Torrent == "" {
				return "", http.StatusBadRequest, sys + " has no torrent in the catalogue"
			}
			return row.Torrent, 0, ""
		}
	}
	return "", http.StatusNotFound, "unknown system " + sys
}
