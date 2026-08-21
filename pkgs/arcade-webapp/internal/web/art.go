// Game art (gauntlet P4): GET /art/{systemKey}/{gameID} serves every
// gallery/detail surface its cover. Preference order: a scraped cover
// from the Skyscraper-cache media layout (<artDir>/<system>/<rom
// basename without ext>/cover.{png,jpg}) when ARCADE_WEBAPP_ART_DIR is
// wired; otherwise a deterministic SVG poster derived from the title —
// hue from an FNV-1a hash of the title, big monogram, wrapped title
// text, accent stripe on a Catppuccin-crust-dark ground.
//
// Determinism is load-bearing: the same title must render identical
// bytes in every process and on every platform, so the strong ETag is
// stable across restarts (same authoring rules as internal/fixture: no
// clock, no randomness, no map iteration).
package web

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"hash/fnv"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// WithArt wires the Skyscraper-cache media root ("" = SVG posters only).
// Read-only: the webapp never writes into the cache.
func WithArt(dir string) Option {
	return func(s *Server) { s.artDir = dir }
}

// svgEscaper escapes text interpolated into poster markup (text nodes and
// attribute values — hence quotes too).
var svgEscaper = strings.NewReplacer(
	"&", "&amp;", "<", "&lt;", ">", "&gt;",
	`"`, "&#34;", "'", "&#39;",
)

// posterSVG renders the fallback poster for a title. A pure function of
// its inputs — byte-identical output for identical input, different bytes
// across titles (the hue alone guarantees divergence).
func posterSVG(title, systemKey string) []byte {
	h := fnv.New32a()
	_, _ = h.Write([]byte(title))
	hue := int(h.Sum32() % 360)

	accent := fmt.Sprintf("hsl(%d 70%% 66%%)", hue)
	glow := fmt.Sprintf("hsl(%d 65%% 50%%)", hue)
	deep := fmt.Sprintf("hsl(%d 45%% 24%%)", hue)

	mono := "?"
	if t := strings.TrimSpace(title); t != "" {
		mono = strings.ToUpper(string([]rune(t)[0]))
	}
	esc := svgEscaper.Replace

	var b strings.Builder
	b.WriteString(`<svg xmlns="http://www.w3.org/2000/svg" width="240" height="320" viewBox="0 0 240 320" role="img" aria-label="`)
	b.WriteString(esc(title))
	b.WriteString(` cover art">`)
	b.WriteString(`<defs><radialGradient id="g" cx="72%" cy="18%" r="95%">`)
	b.WriteString(`<stop offset="0%" stop-color="` + esc(glow) + `" stop-opacity=".32"/>`)
	b.WriteString(`<stop offset="100%" stop-color="#11111b" stop-opacity="0"/>`)
	b.WriteString(`</radialGradient></defs>`)
	b.WriteString(`<rect width="240" height="320" fill="#11111b"/>`)
	b.WriteString(`<rect width="240" height="320" fill="url(#g)"/>`)
	b.WriteString(`<circle cx="34" cy="306" r="96" fill="` + esc(deep) + `" opacity=".5"/>`)
	if sk := esc(strings.ToUpper(systemKey)); sk != "" {
		b.WriteString(`<text x="120" y="34" text-anchor="middle" font-family="system-ui,sans-serif" font-size="10" font-weight="600" letter-spacing="4" fill="#7f849c">` + sk + `</text>`)
	}
	b.WriteString(`<text x="120" y="172" text-anchor="middle" font-family="system-ui,'Segoe UI',sans-serif" font-size="116" font-weight="700" fill="` + esc(accent) + `" opacity=".93">` + esc(mono) + `</text>`)
	y := 238
	for _, ln := range wrapTitle(title, 18, 3) {
		b.WriteString(`<text x="120" y="` + strconv.Itoa(y) + `" text-anchor="middle" font-family="system-ui,'Segoe UI',sans-serif" font-size="14" fill="#cdd6f4">` + esc(ln) + `</text>`)
		y += 19
	}
	b.WriteString(`<rect x="0" y="304" width="240" height="16" fill="` + esc(accent) + `"/>`)
	b.WriteString(`<rect x="0" y="304" width="240" height="3" fill="#cdd6f4" opacity=".75"/>`)
	b.WriteString(`</svg>`)
	return []byte(b.String())
}

// wrapTitle greedily packs whitespace-separated words into lines of at
// most maxChars runes, capped at maxLines. Overflow (extra words, or a
// single word longer than a line — hard-broken) marks the final line
// with an ellipsis. Pure and rune-safe.
func wrapTitle(title string, maxChars, maxLines int) []string {
	var lines []string
	cur := ""
	flush := func() {
		if cur != "" {
			lines = append(lines, cur)
			cur = ""
		}
	}
	for _, w := range strings.Fields(title) {
		if wr := []rune(w); len(wr) > maxChars {
			w = string(wr[:maxChars-1]) + "…"
		}
		switch {
		case cur == "":
			cur = w
		case len(cur)+1+len(w) <= maxChars: // ASCII-width approximation; titles are overwhelmingly Latin here
			cur += " " + w
		default:
			flush()
			cur = w
		}
	}
	flush()
	if len(lines) > maxLines {
		lines = lines[:maxLines]
		if !strings.HasSuffix(lines[maxLines-1], "…") {
			lines[maxLines-1] += "…"
		}
	}
	return lines
}

// openCachedCover looks for <root>/<sys>/<base>/cover.{png,jpg,jpeg}.
// Both variable segments are sanitized before joining (sys is validated
// by the caller, base derives from store rel_paths but is re-checked),
// and the joined path must stay under root — belt and braces on top of
// the mux's path cleaning. Operator-planted symlinks inside the media
// tree are followed deliberately: the tree is trusted, root-owned data,
// same trust posture as the verify reports route.
func openCachedCover(root, sys, base string) (*os.File, string, time.Time, bool) {
	if base == "" || base == "." || base == ".." || strings.ContainsAny(base, `/\`) ||
		sys == "" || sys == "." || sys == ".." || strings.ContainsAny(sys, `/\`) {
		return nil, "", time.Time{}, false
	}
	cleanRoot := filepath.Clean(root)
	dir := filepath.Clean(filepath.Join(cleanRoot, sys, base))
	if dir != cleanRoot && !strings.HasPrefix(dir, cleanRoot+string(os.PathSeparator)) {
		return nil, "", time.Time{}, false
	}
	for _, ext := range []string{".png", ".jpg", ".jpeg"} {
		name := "cover" + ext
		fi, err := os.Stat(filepath.Join(dir, name))
		if err != nil || fi.IsDir() {
			continue
		}
		f, err := os.Open(filepath.Join(dir, name))
		if err != nil {
			continue
		}
		return f, name, fi.ModTime(), true
	}
	return nil, "", time.Time{}, false
}

// etagMatches answers an If-None-Match header against our strong etag
// (comma-separated lists and "*" honored; weak prefixes stripped).
func etagMatches(header, etag string) bool {
	if header == "" {
		return false
	}
	for _, part := range strings.Split(header, ",") {
		part = strings.TrimSpace(part)
		part = strings.TrimPrefix(part, "W/")
		if part == "*" || part == etag {
			return true
		}
	}
	return false
}

// handleArt serves one game's cover: scraped file when configured and
// present, deterministic SVG otherwise, with caching headers either way.
func (s *Server) handleArt(w http.ResponseWriter, r *http.Request) {
	sys := r.PathValue("systemKey")
	id, err := strconv.ParseInt(r.PathValue("gameID"), 10, 64)
	// Traversal-shaped segments never parse as (system, id): encoded
	// slashes make the id non-numeric, dot segments fail the system
	// checks below, and ServeMux cleans raw "../" paths before matching.
	if err != nil || id < 0 {
		http.NotFound(w, r)
		return
	}
	g, err := s.st.GetGame(sys, id)
	if err != nil {
		http.Error(w, "game lookup failed", http.StatusInternalServerError)
		log.Printf("web: art %s/%d: %v", sys, id, err)
		return
	}
	if g == nil || sys == "" || sys == "." || sys == ".." || strings.ContainsAny(sys, `/\`) {
		http.NotFound(w, r)
		return
	}
	title := gameTitle(g.RelPath)

	w.Header().Set("Cache-Control", "public, max-age=86400")
	if s.artDir != "" {
		if f, name, modtime, ok := openCachedCover(s.artDir, sys, title); ok {
			defer f.Close() //nolint:errcheck // read-only
			http.ServeContent(w, r, name, modtime, f)
			return
		}
	}

	svg := posterSVG(title, sys)
	sum := sha256.Sum256(svg)
	etag := `"` + hex.EncodeToString(sum[:16]) + `"`
	w.Header().Set("ETag", etag)
	if etagMatches(r.Header.Get("If-None-Match"), etag) {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.Header().Set("Content-Type", "image/svg+xml")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(svg)
}
