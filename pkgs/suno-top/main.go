// suno-top — harvests Suno's PUBLIC trending feed into the fleet Postgres
// (callisto, db `jupiter`, schema `suno`), accumulating every unique clip seen
// and tracking play-count growth curves over time. The companion to
// pkgs/suno-backup: that one mirrors OUR library; this one vacuums the public
// winners so the catalogue's prompts/tags/engagement become a queryable
// dataset (hit-model research, prompt-style distributions).
//
// Suno ships no official API. Endpoints below were verified UNAUTHENTICATED
// against the production host on 2026-09-04 (discovered via the suno.com web
// app's JS bundle, same method as suno-backup):
//
//   - Discovery: POST https://studio-api.prod.suno.com/api/unified/feed
//     body {"feed_id":"trending","page_size":25} → feed.items[].content_item
//     is the FULL clip object (metadata.prompt/tags, counts, model, …).
//     Capped at 25 items/page; no cursor is granted anonymously. Batch
//     rotation is TIME-VARYING server-side: some periods serve a fresh
//     recommendation batch per request (0/25 overlap at 20s), others hold
//     one batch for minutes (20/25 overlap at 5s) — both regimes observed
//     minutes apart on 2026-09-04, independent of UA/headers/connection
//     reuse. Either way the daemon accumulates: re-sightings are upserted
//     (counts refreshed, history appended) and new batches are picked up as
//     they land.     "trending" is velocity-ranked, not top-by-plays: observed
//     counts on a single page ranged 15–1947. We rank locally in SQL.
//   - Recheck: GET https://studio-api.prod.suno.com/api/clip/<id> → the same
//     clip object, unauthenticated. This turns early snapshots into growth
//     curves: each pass re-polls the highest-play_count clips whose last
//     recheck is older than recheck_min_age.
//   - Creator crawl (THE VOLUME LEVER): GET
//     https://studio-api.prod.suno.com/api/profiles/<handle>/ with
//     ?clips_sort_by=created_at&playlists_sort_by=created_at&page=N returns
//     the profile plus a page of that creator's public clips as FULL clip
//     objects, unauthenticated and paginated all the way to `num_total_clips`
//     (verified 2026-09-19: dheewatara = 4,117 clips over 207 pages). Every
//     clip seen any way queues its handle in suno.creators; the crawl walks
//     that queue one page per creator per pass, so coverage grows
//     breadth-first across the entire public catalogue instead of the ~25 the
//     anonymous trending feed serves.
//   - Tag search (THE NEW FIREHOSE): POST
//     https://studio-api.prod.suno.com/api/search/ with a single
//     {"search_queries":[{"search_type":"tag_song","term":"<tag>",...}]} is
//     public (verified 2026-09-23) and returns FULL clip objects, paginated
//     by from_index/size up to size 100 and total_hits 10,000 per tag.
//     rank_by=upvote_count sorts winners first, so a tag's best clips land on
//     page 1. Measured novelty against the live DB: 6 tags x one 100-clip
//     page = 537 unique clips, 506 unseen, 408 above the 100-upvote floor.
//     The tag queue is seeded from https://suno.com/styles-sitemap.xml (967
//     style slugs, URL-decoded). Endpoint rate-limits (429) under rapid
//     bursts — the per-pass caps exist for politeness.
//   - Playlists (THE GRAPH LANE): GET /api/playlist/<id>/?page=N is public
//     and returns `playlist_clips[].clip` as FULL clip objects. Playlist ids
//     come from profile responses (every profile carries a `playlists` array
//     that the creator crawl used to discard), from the editorial indexes
//     below, and from playlist owners (creatorEnsure). Each playlist adds its
//     clips AND its owner handle, so the creator queue refills forever.
//   - Editorial indexes: POST /api/unified/homepage, /api/unified/explore and
//     /api/unified/homepage/explore/mobile are public and carry
//     playlist_shortcut / playlist-container items. Fetched at most once per
//     SUNO_TOP_EDITORIAL_INTERVAL (default 12h); their playlist ids feed the
//     playlist queue. GET /api/contests/ (public) yields base_clip_ids, queued
//     once into suno.fetch_queue and fetched by the seed lane.
//
// Deliberately NOT used (all verified 401 unauthenticated on 2026-09-23):
// POST /api/feed/v3, POST /api/unified/search/omnisearch, every other
// /api/search/ search_type (public_song, similar_song, typeahead_*, …),
// /api/radio/<tag>/, /api/clips/autoplay, /api/clips/parent,
// /api/clips/aligned_clip_siblings, /api/persona/* and /api/discover/
// shortcuts_songs. This daemon runs credential-free by design; suno-backup
// owns the cookie lane.
//
// Storage shape (schema `suno`, DDL idempotent, applied on start):
//
//	suno.clips         one row per unique clip; raw jsonb keeps the COMPLETE
//	                   clip object verbatim; convenience columns (play_count,
//	                   tags, prompt, lyrics, style_prompt, …) are projections.
//	suno.creators      one row per handle discovered; a queue for the creator
//	                   crawl (next_page cursor, done flag, failure backoff).
//	suno.clip_sightings  append-only observation log: every trending sighting
//	                   (with its 1-based feed rank — the recommendation
//	                   algorithm's opinion, unrecoverable later) and, for
//	                   recheck/creator sightings, only where a count changed.
//	                   This table IS the time-series: velocity curves,
//	                   rotation re-promotions, trending-rank history.
//	suno.tags          tag-search queue: one row per style tag, with the
//	                   from_index cursor (next_index), observed total_hits,
//	                   clips_stored and a done flag.
//	suno.playlists     playlist queue: id, owner handle, song_count, page
//	                   cursor, failure backoff, done flag.
//	suno.fetch_queue   one-shot clip ids to fetch by id (contest base songs);
//	                   source records where the id came from.
//	suno.meta          small key/value bookkeeping (editorial-seed cadence).
//
// Politeness budget (defaults): one discovery POST per interval (3m → 480/day)
// plus up to 20 recheck GETs per pass with a 45m per-clip min-age, plus one
// profile GET per creator per pass (10 creators → ~4.8k/day, each yielding
// 20-30 clips), plus 2 tag-search POSTs and 3 playlist GETs and 5 seed GETs
// per pass (~3.8k/day combined). All single small JSON requests — a browser
// tab's worth of traffic. Dial any lane to 0 to disable it; raise INTERVAL to
// slow everything down. The search endpoint 429s under rapid bursts, so lanes
// sleep 300ms between requests and share one per-pass cap.
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	_ "github.com/lib/pq"
)

const (
	appName = "suno-top"

	apiBase      = "https://studio-api.prod.suno.com"
	feedPath     = "/api/unified/feed"
	clipPath     = "/api/clip/"
	profilePath  = "/api/profiles/"
	searchPath   = "/api/search/"
	playlistPath = "/api/playlist/"
	contestsPath = "/api/contests/"

	// stylesSitemapURL is suno.com's style index: one <loc> per style slug,
	// the seed vocabulary for the tag-search lane (967 slugs on 2026-09-23).
	stylesSitemapURL = "https://suno.com/styles-sitemap.xml"

	// searchPageCap is the largest accepted tag-search size (verified
	// 2026-09-23) and the hard cap for SUNO_TOP_TAG_PAGE_SIZE.
	searchPageCap = 100

	// profilePageApprox is the page size the profile endpoint uses after page
	// 1 (page 1 returns 30, the rest 20). Only used to decide when a walk is
	// finished, never to size requests — the server owns the size.
	profilePageApprox = 20

	// creatorDelay paces the creator crawl between profile GETs.
	creatorDelay = 300 * time.Millisecond

	defaultUA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

	// The feed has never returned more than 25 items/page regardless of
	// page_size (verified 2026-09-04); larger values yield EMPTY pages, so
	// this is both the default and the hard cap.
	pageSizeCap = 25
)

// editorialPaths are the public index endpoints that carry playlist
// references; all verified 200 unauthenticated (2026-09-23).
var editorialPaths = []string{
	"/api/unified/homepage",
	"/api/unified/explore",
	"/api/unified/homepage/explore/mobile",
}

type config struct {
	databaseURL      string
	interval         time.Duration
	pageSize         int
	rechecks         int
	recheckMinAge    time.Duration
	creators         int
	minUpvotes       int
	tagsPerPass      int
	tagPageSize      int
	playlistsPerPass int
	seedsPerPass     int
	editorialEvery   time.Duration
	jitterFrac       float64
	once             bool
	httpTimeout      time.Duration
	dbTimeout        time.Duration
}

func loadConfig(log *slog.Logger) config {
	geti := func(k string, def int) int {
		if s := os.Getenv(k); s != "" {
			if v, err := strconv.Atoi(s); err == nil {
				return v
			}
		}
		return def
	}
	getd := func(k string, def time.Duration) time.Duration {
		if s := os.Getenv(k); s != "" {
			if d, err := time.ParseDuration(s); err == nil {
				return d
			}
		}
		return def
	}
	getf := func(k string, def float64) float64 {
		if s := os.Getenv(k); s != "" {
			if v, err := strconv.ParseFloat(s, 64); err == nil {
				return v
			}
		}
		return def
	}
	ps := geti("SUNO_TOP_PAGE_SIZE", pageSizeCap)
	if ps > pageSizeCap {
		ps = pageSizeCap
	}
	tps := geti("SUNO_TOP_TAG_PAGE_SIZE", searchPageCap)
	if tps > searchPageCap {
		tps = searchPageCap
	}
	cfg := config{
		databaseURL:      os.Getenv("SUNO_TOP_DATABASE_URL"),
		interval:         getd("SUNO_TOP_INTERVAL", 3*time.Minute),
		pageSize:         ps,
		rechecks:         geti("SUNO_TOP_RECHECKS", 20),
		recheckMinAge:    getd("SUNO_TOP_RECHECK_MIN_AGE", 45*time.Minute),
		creators:         geti("SUNO_TOP_CREATORS", 10),
		minUpvotes:       geti("SUNO_TOP_MIN_UPVOTES", 100),
		tagsPerPass:      geti("SUNO_TOP_TAGS", 2),
		tagPageSize:      tps,
		playlistsPerPass: geti("SUNO_TOP_PLAYLISTS", 3),
		seedsPerPass:     geti("SUNO_TOP_SEEDS", 5),
		editorialEvery:   getd("SUNO_TOP_EDITORIAL_INTERVAL", 12*time.Hour),
		jitterFrac:       getf("SUNO_TOP_JITTER", 0.15),
		once:             os.Getenv("SUNO_TOP_ONCE") == "1",
		httpTimeout:      getd("SUNO_TOP_HTTP_TIMEOUT", 30*time.Second),
		dbTimeout:        getd("SUNO_TOP_DB_TIMEOUT", 30*time.Second),
	}
	if cfg.databaseURL == "" {
		// Fall back to the fleet-wide convention where the procurement stack
		// already lives.
		if s := os.Getenv("DATABASE_URL"); s != "" {
			cfg.databaseURL = s
		}
	}
	log.Info("config loaded",
		"interval", cfg.interval, "page_size", cfg.pageSize,
		"rechecks", cfg.rechecks, "recheck_min_age", cfg.recheckMinAge,
		"creators", cfg.creators, "min_upvotes", cfg.minUpvotes,
		"tags", cfg.tagsPerPass, "tag_page_size", cfg.tagPageSize,
		"playlists", cfg.playlistsPerPass, "seeds", cfg.seedsPerPass,
		"editorial_interval", cfg.editorialEvery,
		"jitter", cfg.jitterFrac, "once", cfg.once)
	return cfg
}

// ------------------------------- Suno client --------------------------------

type sunoClient struct {
	http *http.Client
	log  *slog.Logger
}

// feedResponse models POST /api/unified/feed. Items' content_item payloads are
// kept verbatim — that json is what lands in suno.clips.raw.
type feedResponse struct {
	Feed struct {
		FeedID    string `json:"feed_id"`
		FeedTitle string `json:"feed_title"`
		Items     []struct {
			ContentID   string          `json:"content_id"`
			ContentType string          `json:"content_type"`
			ContentItem json.RawMessage `json:"content_item"`
		} `json:"items"`
	} `json:"feed"`
}

// profileResponse models GET /api/profiles/<handle>/. `clips` are FULL clip
// objects (same shape as the feed's content_item) and are landed verbatim.
// `playlists` is the public playlist index of the profile — every id here is
// a discovery edge (playlist lane), which is why the crawl queues them.
type profileResponse struct {
	UserID        string            `json:"user_id"`
	DisplayName   string            `json:"display_name"`
	Handle        string            `json:"handle"`
	NumTotalClips int64             `json:"num_total_clips"`
	CurrentPage   int               `json:"current_page"`
	Clips         []json.RawMessage `json:"clips"`
	Playlists     []profilePlaylist `json:"playlists"`
}

type profilePlaylist struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	UserHandle string `json:"user_handle"`
	SongCount  int64  `json:"song_count"`
	IsPublic   *bool  `json:"is_public"`
	IsHidden   *bool  `json:"is_hidden"`
	IsTrashed  *bool  `json:"is_trashed"`
}

// clipFields is the projection of the clip object we index. The FULL object
// always travels in `raw`; fields here are conveniences for SQL.
type clipFields struct {
	ID                string
	Title             string
	Handle            string
	DisplayName       string
	UserID            string
	PlayCount         int64
	UpvoteCount       int64
	CommentCount      int64
	CreatedAt         sql.NullTime
	MajorModelVersion string
	ModelName         string
	DurationSec       sql.NullFloat64
	Tags              string
	Prompt            string // metadata.prompt — lyrics for custom-mode clips
	StylePrompt       string // metadata.gpt_description_prompt — simple-mode description
	PromptMode        string // metadata.type, best-effort ('custom' | 'simple' | '')
	IsPublic          *bool
	IsExplicit        *bool
	IsRemix           *bool
}

type clipMetadata struct {
	Prompt               *string  `json:"prompt"`
	Tags                 *string  `json:"tags"`
	GptDescriptionPrompt *string  `json:"gpt_description_prompt"`
	Duration             *float64 `json:"duration"`
	Type                 *string  `json:"type"`
	Task                 *string  `json:"task"`
	IsRemix              *bool    `json:"is_remix"`
}

func parseClip(raw json.RawMessage) (clipFields, error) {
	var cf clipFields
	var top struct {
		ID                string       `json:"id"`
		Title             string       `json:"title"`
		Handle            *string      `json:"handle"`
		DisplayName       *string      `json:"display_name"`
		UserID            *string      `json:"user_id"`
		PlayCount         *int64       `json:"play_count"`
		UpvoteCount       *int64       `json:"upvote_count"`
		CommentCount      *int64       `json:"comment_count"`
		CreatedAt         *string      `json:"created_at"`
		MajorModelVersion *string      `json:"major_model_version"`
		ModelName         *string      `json:"model_name"`
		IsPublic          *bool        `json:"is_public"`
		Explicit          *bool        `json:"explicit"`
		Metadata          clipMetadata `json:"metadata"`
	}
	if err := json.Unmarshal(raw, &top); err != nil {
		return cf, fmt.Errorf("unmarshal clip: %w", err)
	}
	if top.ID == "" {
		return cf, errors.New("clip has no id")
	}
	cf.ID = top.ID
	cf.Title = top.Title
	cf.Handle = derefStr(top.Handle)
	cf.DisplayName = derefStr(top.DisplayName)
	cf.UserID = derefStr(top.UserID)
	cf.PlayCount = derefI(top.PlayCount)
	cf.UpvoteCount = derefI(top.UpvoteCount)
	cf.CommentCount = derefI(top.CommentCount)
	if top.CreatedAt != nil {
		for _, layout := range []string{time.RFC3339Nano, time.RFC3339} {
			if t, err := time.Parse(layout, *top.CreatedAt); err == nil {
				cf.CreatedAt = sql.NullTime{Time: t, Valid: true}
				break
			}
		}
	}
	cf.MajorModelVersion = derefStr(top.MajorModelVersion)
	cf.ModelName = derefStr(top.ModelName)
	cf.IsPublic = top.IsPublic
	cf.IsExplicit = top.Explicit
	cf.IsRemix = top.Metadata.IsRemix
	if top.Metadata.Duration != nil {
		cf.DurationSec = sql.NullFloat64{Float64: *top.Metadata.Duration, Valid: true}
	}
	cf.Tags = derefStr(top.Metadata.Tags)
	if top.Metadata.Prompt != nil {
		cf.Prompt = *top.Metadata.Prompt
	}
	if top.Metadata.GptDescriptionPrompt != nil {
		cf.StylePrompt = *top.Metadata.GptDescriptionPrompt
	}
	if top.Metadata.Type != nil {
		cf.PromptMode = strings.ToLower(*top.Metadata.Type)
	} else if top.Metadata.Task != nil {
		cf.PromptMode = strings.ToLower(*top.Metadata.Task)
	}
	return cf, nil
}

func derefStr(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func derefI(p *int64) int64 {
	if p == nil {
		return 0
	}
	return *p
}

func (c *sunoClient) postJSON(ctx context.Context, path string, body any, out any) error {
	var buf bytes.Buffer
	if err := json.NewEncoder(&buf).Encode(body); err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, apiBase+path, &buf)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", defaultUA)
	req.Header.Set("Origin", "https://suno.com")
	req.Header.Set("Referer", "https://suno.com/")
	return c.do(req, out)
}

func (c *sunoClient) getJSON(ctx context.Context, path string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, apiBase+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", defaultUA)
	req.Header.Set("Origin", "https://suno.com")
	req.Header.Set("Referer", "https://suno.com/")
	return c.do(req, out)
}

func (c *sunoClient) do(req *http.Request, out any) error {
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusTooManyRequests {
		return errors.New("rate limited (429) — back off")
	}
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("%s %s: status %d: %s", req.Method, req.URL.Path,
			resp.StatusCode, strings.TrimSpace(string(b)))
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// fetchTrending pulls one rotation of the trending feed.
func (c *sunoClient) fetchTrending(ctx context.Context, pageSize int) ([]json.RawMessage, error) {
	var fr feedResponse
	body := map[string]any{"feed_id": "trending", "page_size": pageSize}
	if err := c.postJSON(ctx, feedPath, body, &fr); err != nil {
		return nil, fmt.Errorf("unified/feed: %w", err)
	}
	var clips []json.RawMessage
	for _, it := range fr.Feed.Items {
		if it.ContentType != "clip" || len(it.ContentItem) == 0 {
			continue
		}
		clips = append(clips, it.ContentItem)
	}
	return clips, nil
}

// fetchClip re-polls one clip by id (growth-curve maintenance).
func (c *sunoClient) fetchClip(ctx context.Context, id string) (json.RawMessage, error) {
	var raw json.RawMessage
	if err := c.getJSON(ctx, clipPath+id, &raw); err != nil {
		return nil, fmt.Errorf("clip %s: %w", id, err)
	}
	return raw, nil
}

// fetchCreatorClips pulls one page of a creator's public clips. The two sort
// params are mandatory (the endpoint 422s without them) and `page` is 1-based,
// returning 30 clips on page 1 and ~20 thereafter.
func (c *sunoClient) fetchCreatorClips(ctx context.Context, handle string, page int) ([]json.RawMessage, profileResponse, error) {
	var pr profileResponse
	path := fmt.Sprintf("%s%s/?clips_sort_by=created_at&playlists_sort_by=created_at&page=%d",
		profilePath, url.PathEscape(handle), page)
	if err := c.getJSON(ctx, path, &pr); err != nil {
		return nil, pr, fmt.Errorf("profile %s p%d: %w", handle, page, err)
	}
	return pr.Clips, pr, nil
}

// ------------------------------- Tag search ---------------------------------

// tagSearchResponse models POST /api/search/ with a single tag_song query.
// The server keys the result map by the query `name`, so lookups go through
// the name with a single-entry fallback.
type tagSearchResponse struct {
	Result map[string]struct {
		TotalHits int               `json:"total_hits"`
		Result    []json.RawMessage `json:"result"`
	} `json:"result"`
}

// fetchTagPage pulls one page of public clips carrying `tag` (the clip's
// display_tags). Verified unauthenticated 2026-09-23; size is capped at 100 by
// the server and total_hits saturates at 10,000. rank_by=upvote_count sorts
// winners first, which is what lets tagPageAdvance stop early once a whole
// page falls below the quality floor.
func (c *sunoClient) fetchTagPage(ctx context.Context, tag string, fromIndex, size int) ([]json.RawMessage, int, error) {
	query := map[string]any{
		"name": "tag_song", "search_type": "tag_song", "term": tag,
		"from_index": fromIndex, "size": size, "rank_by": "upvote_count",
		"is_public": true, "is_instrumental": false,
		"model_versions": []string{}, "languages": []string{}, "creator_filters": []string{},
	}
	var tr tagSearchResponse
	if err := c.postJSON(ctx, searchPath, map[string]any{"search_queries": []any{query}}, &tr); err != nil {
		return nil, 0, fmt.Errorf("tag %q: %w", tag, err)
	}
	entry, ok := tr.Result["tag_song"]
	if !ok {
		for _, v := range tr.Result {
			entry, ok = v, true
			break
		}
	}
	if !ok {
		return nil, 0, fmt.Errorf("tag %q: response carried no results", tag)
	}
	return entry.Result, entry.TotalHits, nil
}

// tagPageAdvance computes the next from_index and whether a tag's walk is
// finished. With rank_by=upvote_count the page is sorted descending, so if the
// page's best clip is below the floor, every later page is too.
func tagPageAdvance(fromIndex, pageLen, totalHits, maxUpvotes, floor int64) (next int64, done bool) {
	next = fromIndex + pageLen
	if pageLen == 0 {
		return next, true
	}
	if totalHits > 0 && next >= totalHits {
		return next, true
	}
	if floor > 0 && maxUpvotes < floor {
		return next, true
	}
	return next, false
}

// ------------------------------- Playlists ----------------------------------

// playlistResponse models GET /api/playlist/<id>/?page=N. `playlist_clips`
// entries wrap the FULL clip object under `clip`; entries with a null clip
// (deleted songs) are skipped by the lane. Verified public 2026-09-23.
type playlistResponse struct {
	ID            string `json:"id"`
	Name          string `json:"name"`
	UserHandle    string `json:"user_handle"`
	SongCount     int64  `json:"song_count"`
	NumTotal      int64  `json:"num_total_results"`
	CurrentPage   int    `json:"current_page"`
	PlaylistClips []struct {
		Clip json.RawMessage `json:"clip"`
	} `json:"playlist_clips"`
}

func (c *sunoClient) fetchPlaylistPage(ctx context.Context, id string, page int) (playlistResponse, error) {
	var pr playlistResponse
	path := fmt.Sprintf("%s%s/?page=%d", playlistPath, url.PathEscape(id), page)
	if err := c.getJSON(ctx, path, &pr); err != nil {
		return pr, fmt.Errorf("playlist %s p%d: %w", id, page, err)
	}
	return pr, nil
}

// ------------------------------- Editorial ----------------------------------

// editorialResponse models the public index endpoints (editorialPaths). Only
// the playlist references matter to the daemon.
type editorialResponse struct {
	Feeds []struct {
		Items []struct {
			ContentType string `json:"content_type"`
			ContentItem struct {
				PlaylistID        string `json:"playlist_id"`
				PlaylistName      string `json:"playlist_name"`
				SongCount         int64  `json:"playlist_song_count"`
				UserHandle        string `json:"playlist_user_handle"`
				FeedContainerID   string `json:"feed_container_id"`
				FeedContainerType string `json:"feed_container_type"`
			} `json:"content_item"`
		} `json:"items"`
	} `json:"feeds"`
}

type playlistRef struct {
	id         string
	name       string
	userHandle string
	songCount  int64
}

// collectPlaylistRefs extracts every playlist reference from one editorial
// response: explicit playlist_shortcut items and playlist feed containers.
func collectPlaylistRefs(er editorialResponse) []playlistRef {
	seen := map[string]bool{}
	var refs []playlistRef
	add := func(id, name, handle string, songs int64) {
		if id == "" || seen[id] {
			return
		}
		seen[id] = true
		refs = append(refs, playlistRef{id: id, name: name, userHandle: handle, songCount: songs})
	}
	for _, f := range er.Feeds {
		for _, it := range f.Items {
			ci := it.ContentItem
			add(ci.PlaylistID, ci.PlaylistName, ci.UserHandle, ci.SongCount)
			if ci.FeedContainerType == "playlist" {
				add(ci.FeedContainerID, "", "", 0)
			}
		}
	}
	return refs
}

// fetchEditorial pulls every editorial index and returns the deduped playlist
// references. Individual endpoint failures are logged and skipped; the error
// return is non-nil only when every index failed.
func (c *sunoClient) fetchEditorial(ctx context.Context) ([]playlistRef, error) {
	ok := 0
	seen := map[string]bool{}
	var refs []playlistRef
	var lastErr error
	for _, path := range editorialPaths {
		var er editorialResponse
		if err := c.postJSON(ctx, path, map[string]any{}, &er); err != nil {
			c.log.Warn("editorial index failed", "path", path, "err", err)
			lastErr = err
			continue
		}
		ok++
		for _, ref := range collectPlaylistRefs(er) {
			if seen[ref.id] {
				continue
			}
			seen[ref.id] = true
			refs = append(refs, ref)
		}
	}
	if ok == 0 {
		return nil, fmt.Errorf("all editorial indexes failed: %w", lastErr)
	}
	return refs, nil
}

// -------------------------------- Contests ----------------------------------

type contestResponse struct {
	Contests []struct {
		ID          string   `json:"id"`
		Name        string   `json:"name"`
		BaseClipIDs []string `json:"base_clip_ids"`
	} `json:"contests"`
}

// fetchContestSeeds returns the public contest base-clip ids — one-shot seed
// material for suno.fetch_queue. Verified public 2026-09-23.
func (c *sunoClient) fetchContestSeeds(ctx context.Context) ([]string, error) {
	var cr contestResponse
	if err := c.getJSON(ctx, contestsPath, &cr); err != nil {
		return nil, fmt.Errorf("contests: %w", err)
	}
	var ids []string
	for _, ct := range cr.Contests {
		ids = append(ids, ct.BaseClipIDs...)
	}
	return ids, nil
}

// ------------------------------- Tag seeding --------------------------------

var styleLocRe = regexp.MustCompile(`https://suno\.com/style/([^<]+)`)

// fetchStylesSitemap returns the style slugs from suno.com's public sitemap:
// the seed vocabulary for the tag-search queue. Slugs are URL-decoded
// ("r%26b" → "r&b"); hyphenated slugs are kept as-is because the search
// endpoint matches "hip-hop" against the "hip hop" tag (verified 2026-09-23).
func (c *sunoClient) fetchStylesSitemap(ctx context.Context) ([]string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, stylesSitemapURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", defaultUA)
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("styles sitemap: status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	var tags []string
	for _, m := range styleLocRe.FindAllStringSubmatch(string(body), -1) {
		slug := strings.TrimSuffix(strings.TrimSpace(m[1]), "/")
		if dec, derr := url.PathUnescape(slug); derr == nil {
			slug = dec
		}
		if slug == "" || seen[slug] {
			continue
		}
		seen[slug] = true
		tags = append(tags, slug)
	}
	return tags, nil
}

// --------------------------------- Storage ----------------------------------

const schemaDDL = `
CREATE SCHEMA IF NOT EXISTS suno;

CREATE TABLE IF NOT EXISTS suno.clips (
	id                  text PRIMARY KEY,
	title               text NOT NULL DEFAULT '',
	handle              text NOT NULL DEFAULT '',
	display_name        text NOT NULL DEFAULT '',
	user_id             text NOT NULL DEFAULT '',
	play_count          bigint NOT NULL DEFAULT 0,
	upvote_count        bigint NOT NULL DEFAULT 0,
	comment_count       bigint NOT NULL DEFAULT 0,
	created_at          timestamptz,
	first_seen_at       timestamptz NOT NULL DEFAULT now(),
	last_seen_at        timestamptz NOT NULL DEFAULT now(),
	last_rechecked_at   timestamptz,
	major_model_version text NOT NULL DEFAULT '',
	model_name          text NOT NULL DEFAULT '',
	duration_sec        double precision,
	tags                text NOT NULL DEFAULT '',
	prompt              text NOT NULL DEFAULT '',
	style_prompt        text NOT NULL DEFAULT '',
	prompt_mode         text NOT NULL DEFAULT '',
	is_public           boolean,
	is_explicit         boolean,
	is_remix            boolean,
	raw                 jsonb NOT NULL
);

CREATE INDEX IF NOT EXISTS suno_clips_play_count_idx ON suno.clips (play_count DESC);
CREATE INDEX IF NOT EXISTS suno_clips_created_at_idx ON suno.clips (created_at);
CREATE INDEX IF NOT EXISTS suno_clips_last_rechecked_idx ON suno.clips (last_rechecked_at);

CREATE TABLE IF NOT EXISTS suno.creators (
	handle          text PRIMARY KEY,
	user_id         text NOT NULL DEFAULT '',
	display_name    text NOT NULL DEFAULT '',
	total_clips     bigint NOT NULL DEFAULT 0,   -- profile num_total_clips
	next_page       integer NOT NULL DEFAULT 1,  -- 1-based crawl cursor
	clips_indexed   bigint NOT NULL DEFAULT 0,   -- clips stored from this creator
	failures        integer NOT NULL DEFAULT 0,
	done            boolean NOT NULL DEFAULT false,
	last_error      text NOT NULL DEFAULT '',
	discovered_at   timestamptz NOT NULL DEFAULT now(),
	last_crawled_at timestamptz
);

CREATE INDEX IF NOT EXISTS suno_creators_queue_idx ON suno.creators (done, last_crawled_at, discovered_at);

CREATE TABLE IF NOT EXISTS suno.clip_sightings (
	id            bigserial PRIMARY KEY,
	clip_id       text NOT NULL REFERENCES suno.clips(id) ON DELETE CASCADE,
	seen_at       timestamptz NOT NULL DEFAULT now(),
	source        text NOT NULL,           -- 'trending' | 'recheck' | 'creator' | 'tag_search' | 'playlist' | 'contest'
	trending_rank integer,                 -- 1-based position in the feed, NULL otherwise
	play_count    bigint NOT NULL,
	upvote_count  bigint NOT NULL,
	comment_count bigint NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS suno_clip_sightings_clip_idx ON suno.clip_sightings (clip_id, seen_at);

CREATE TABLE IF NOT EXISTS suno.tags (
	tag             text PRIMARY KEY,
	next_index      integer NOT NULL DEFAULT 0,  -- tag-search from_index cursor
	total_hits      integer NOT NULL DEFAULT 0,  -- observed total_hits (saturates at 10000)
	clips_stored    bigint NOT NULL DEFAULT 0,   -- qualifying clips stored from this tag
	failures        integer NOT NULL DEFAULT 0,
	done            boolean NOT NULL DEFAULT false,
	last_error      text NOT NULL DEFAULT '',
	discovered_at   timestamptz NOT NULL DEFAULT now(),
	last_crawled_at timestamptz
);

CREATE INDEX IF NOT EXISTS suno_tags_queue_idx ON suno.tags (done, last_crawled_at, discovered_at);

CREATE TABLE IF NOT EXISTS suno.playlists (
	id              text PRIMARY KEY,
	name            text NOT NULL DEFAULT '',
	user_handle     text NOT NULL DEFAULT '',
	song_count      bigint NOT NULL DEFAULT 0,
	next_page       integer NOT NULL DEFAULT 1,  -- 1-based page cursor
	clips_indexed   bigint NOT NULL DEFAULT 0,   -- qualifying clips stored so far
	done            boolean NOT NULL DEFAULT false,
	failures        integer NOT NULL DEFAULT 0,
	last_error      text NOT NULL DEFAULT '',
	discovered_at   timestamptz NOT NULL DEFAULT now(),
	last_crawled_at timestamptz
);

CREATE INDEX IF NOT EXISTS suno_playlists_queue_idx ON suno.playlists (done, last_crawled_at, discovered_at);

CREATE TABLE IF NOT EXISTS suno.fetch_queue (
	id            text PRIMARY KEY,
	source        text NOT NULL DEFAULT '',      -- provenance of the id ('contest')
	attempts      integer NOT NULL DEFAULT 0,
	done          boolean NOT NULL DEFAULT false,
	last_error    text NOT NULL DEFAULT '',
	discovered_at timestamptz NOT NULL DEFAULT now(),
	fetched_at    timestamptz
);

CREATE INDEX IF NOT EXISTS suno_fetch_queue_idx ON suno.fetch_queue (done, attempts, discovered_at);

CREATE TABLE IF NOT EXISTS suno.meta (
	key        text PRIMARY KEY,
	value      text NOT NULL DEFAULT '',
	updated_at timestamptz NOT NULL DEFAULT now()
);
`

const clipUpsert = `
INSERT INTO suno.clips (
	id, title, handle, display_name, user_id,
	play_count, upvote_count, comment_count, created_at,
	major_model_version, model_name, duration_sec,
	tags, prompt, style_prompt, prompt_mode,
	is_public, is_explicit, is_remix, last_rechecked_at, raw
) VALUES (
	$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,
	CASE WHEN $20::boolean THEN now() ELSE NULL END,
	$21
)
ON CONFLICT (id) DO UPDATE SET
	title               = EXCLUDED.title,
	handle              = EXCLUDED.handle,
	display_name        = EXCLUDED.display_name,
	user_id             = EXCLUDED.user_id,
	play_count          = EXCLUDED.play_count,
	upvote_count        = EXCLUDED.upvote_count,
	comment_count       = EXCLUDED.comment_count,
	created_at          = COALESCE(EXCLUDED.created_at, suno.clips.created_at),
	major_model_version = EXCLUDED.major_model_version,
	model_name          = EXCLUDED.model_name,
	duration_sec        = COALESCE(EXCLUDED.duration_sec, suno.clips.duration_sec),
	tags                = EXCLUDED.tags,
	prompt              = EXCLUDED.prompt,
	style_prompt        = EXCLUDED.style_prompt,
	prompt_mode         = EXCLUDED.prompt_mode,
	is_public           = COALESCE(EXCLUDED.is_public, suno.clips.is_public),
	is_explicit         = COALESCE(EXCLUDED.is_explicit, suno.clips.is_explicit),
	is_remix            = COALESCE(EXCLUDED.is_remix, suno.clips.is_remix),
	last_seen_at        = now(),
	raw                 = EXCLUDED.raw,
	last_rechecked_at   = CASE WHEN $22::boolean
		THEN now()
		ELSE suno.clips.last_rechecked_at END
`

const sightingInsert = `
INSERT INTO suno.clip_sightings
	(clip_id, source, trending_rank, play_count, upvote_count, comment_count)
VALUES ($1,$2,$3,$4,$5,$6)
`

// creatorEnsure queues a handle for the creator crawl. Every clip seen by any
// lane feeds this, so coverage grows breadth-first from whatever is discovered.
const creatorEnsure = `
INSERT INTO suno.creators (handle, user_id, display_name)
VALUES ($1, $2, $3)
ON CONFLICT (handle) DO UPDATE SET
	user_id      = CASE WHEN EXCLUDED.user_id <> ''      THEN EXCLUDED.user_id      ELSE suno.creators.user_id END,
	display_name = CASE WHEN EXCLUDED.display_name <> '' THEN EXCLUDED.display_name ELSE suno.creators.display_name END
`

// tagEnsure queues a tag for the tag-search lane.
const tagEnsure = `INSERT INTO suno.tags (tag) VALUES ($1) ON CONFLICT (tag) DO NOTHING`

// playlistEnsure queues a playlist for the playlist lane. Richer metadata
// from a later discovery overwrites placeholders but never shrinks song_count.
const playlistEnsure = `
INSERT INTO suno.playlists (id, name, user_handle, song_count)
VALUES ($1, $2, $3, $4)
ON CONFLICT (id) DO UPDATE SET
	name        = CASE WHEN EXCLUDED.name <> ''        THEN EXCLUDED.name        ELSE suno.playlists.name END,
	user_handle = CASE WHEN EXCLUDED.user_handle <> '' THEN EXCLUDED.user_handle ELSE suno.playlists.user_handle END,
	song_count  = GREATEST(suno.playlists.song_count, EXCLUDED.song_count)
`

// seedEnsure queues a one-shot clip id (contest base songs) for the seed lane.
const seedEnsure = `INSERT INTO suno.fetch_queue (id, source) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING`

// meetsThreshold is the quality gate: only clips at or above the configured
// upvote floor enter the dataset. Applied in every lane, so trending picks a
// low-upvote clip up again once it crosses the floor.
func (c config) meetsThreshold(cf clipFields) bool {
	return c.minUpvotes <= 0 || cf.UpvoteCount >= int64(c.minUpvotes)
}

// storeClip upserts one clip and appends a sighting row. Discovery sightings
// are always recorded (the trending rank is signal); recheck sightings are
// recorded only when a count actually changed (pure growth-curve points).
func storeClip(ctx context.Context, db *sql.DB, cf clipFields, raw json.RawMessage, source string, rank int) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck — commit below owns the outcome

	var prevPlay, prevUp, prevComment sql.NullInt64
	err = tx.QueryRowContext(ctx,
		`SELECT play_count, upvote_count, comment_count FROM suno.clips WHERE id = $1 FOR UPDATE`,
		cf.ID).Scan(&prevPlay, &prevUp, &prevComment)
	exists := err == nil
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("select existing clip: %w", err)
	}

	isRecheck := source == "recheck"
	if _, err := tx.ExecContext(ctx, clipUpsert,
		cf.ID, cf.Title, cf.Handle, cf.DisplayName, cf.UserID,
		cf.PlayCount, cf.UpvoteCount, cf.CommentCount, cf.CreatedAt,
		cf.MajorModelVersion, cf.ModelName, cf.DurationSec,
		cf.Tags, cf.Prompt, cf.StylePrompt, cf.PromptMode,
		cf.IsPublic, cf.IsExplicit, cf.IsRemix, isRecheck, raw, isRecheck,
	); err != nil {
		return fmt.Errorf("upsert clip: %w", err)
	}

	if cf.Handle != "" {
		if _, err := tx.ExecContext(ctx, creatorEnsure, cf.Handle, cf.UserID, cf.DisplayName); err != nil {
			return fmt.Errorf("ensure creator: %w", err)
		}
	}

	shouldRecord := source == "trending" ||
		!exists ||
		prevPlay.Int64 != cf.PlayCount ||
		prevUp.Int64 != cf.UpvoteCount ||
		prevComment.Int64 != cf.CommentCount
	if shouldRecord {
		var rankArg any
		if source == "trending" {
			rankArg = rank
		}
		if _, err := tx.ExecContext(ctx, sightingInsert,
			cf.ID, source, rankArg, cf.PlayCount, cf.UpvoteCount, cf.CommentCount,
		); err != nil {
			return fmt.Errorf("insert sighting: %w", err)
		}
	}
	return tx.Commit()
}

// pickRechecks selects the highest-play clips due for a re-poll: growth curves
// matter most for the winners, and the min-age filter bounds request volume.
//
// The min age is passed as SECONDS and built with make_interval: a bare
// time.Duration reaching Postgres is a plain int64 (database/sql/libpq), which
// the server parses as a number of seconds-turned-interval — i.e. 45m becomes
// 2700000000000s (~85,000 years) and rechecks never fire after the initial
// last_rechecked_at IS NULL pass. Found live 2026-09-18.
func pickRechecks(ctx context.Context, db *sql.DB, limit int, minAge time.Duration) ([]string, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT id FROM suno.clips
		WHERE (last_rechecked_at IS NULL OR now() - last_rechecked_at > make_interval(secs => $1))
		ORDER BY play_count DESC
		LIMIT $2`, minAge.Seconds(), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// ---------------------------------- Daemon ----------------------------------

type daemon struct {
	cfg  config
	suno *sunoClient
	db   *sql.DB
	log  *slog.Logger
}

func (d *daemon) ensureSchema(ctx context.Context) error {
	if _, err := d.db.ExecContext(ctx, schemaDDL); err != nil {
		return fmt.Errorf("ensure schema: %w", err)
	}
	return nil
}

// harvestPass pulls one trending rotation and stores every clip.
func (d *daemon) harvestPass(ctx context.Context) error {
	clips, err := d.suno.fetchTrending(ctx, d.cfg.pageSize)
	if err != nil {
		return err
	}
	fresh := 0
	for i, raw := range clips {
		cf, err := parseClip(raw)
		if err != nil {
			d.log.Warn("skipping unparseable clip", "err", err)
			continue
		}
		if !d.cfg.meetsThreshold(cf) {
			continue
		}
		var exists int
		_ = d.db.QueryRowContext(ctx, `SELECT 1 FROM suno.clips WHERE id=$1`, cf.ID).Scan(&exists)
		if err := storeClip(ctx, d.db, cf, raw, "trending", i+1); err != nil {
			d.log.Warn("store failed", "id", cf.ID, "err", err)
			continue
		}
		if exists == 0 {
			fresh++
		}
	}
	var total int
	_ = d.db.QueryRowContext(ctx, `SELECT count(*) FROM suno.clips`).Scan(&total)
	var topPlay sql.NullInt64
	_ = d.db.QueryRowContext(ctx, `SELECT max(play_count) FROM suno.clips`).Scan(&topPlay)
	d.log.Info("harvest pass done",
		"items", len(clips), "fresh", fresh, "total_indexed", total,
		"max_play_count", topPlay.Int64)
	return nil
}

// recheckPass re-polls high-value clips to build growth curves.
func (d *daemon) recheckPass(ctx context.Context) error {
	if d.cfg.rechecks <= 0 {
		return nil
	}
	ids, err := pickRechecks(ctx, d.db, d.cfg.rechecks, d.cfg.recheckMinAge)
	if err != nil {
		return fmt.Errorf("pick rechecks: %w", err)
	}
	if len(ids) == 0 {
		return nil
	}
	updated := 0
	for _, id := range ids {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		raw, err := d.suno.fetchClip(ctx, id)
		if err != nil {
			d.log.Warn("recheck failed", "id", id, "err", err)
			continue
		}
		cf, err := parseClip(raw)
		if err != nil {
			d.log.Warn("recheck unparseable", "id", id, "err", err)
			continue
		}
		if !d.cfg.meetsThreshold(cf) {
			continue
		}
		if err := storeClip(ctx, d.db, cf, raw, "recheck", 0); err != nil {
			d.log.Warn("recheck store failed", "id", id, "err", err)
			continue
		}
		updated++
	}
	d.log.Info("recheck pass done", "polled", len(ids), "stored", updated)
	return nil
}

// --------------------------------- Creator crawl ----------------------------

// seedCreators queues every handle already known from stored clips. Idempotent;
// runs at startup so an existing database backfills the crawl queue.
func (d *daemon) seedCreators(ctx context.Context) error {
	res, err := d.db.ExecContext(ctx, `
		INSERT INTO suno.creators (handle)
		SELECT DISTINCT handle FROM suno.clips WHERE handle <> ''
		ON CONFLICT (handle) DO NOTHING`)
	if err != nil {
		return fmt.Errorf("seed creators: %w", err)
	}
	if n, _ := res.RowsAffected(); n > 0 {
		d.log.Info("creator queue seeded", "added", n)
	}
	return nil
}

// pruneBelowThreshold enforces the upvote floor on an existing database: rows
// (and their sightings, via cascade) below the floor are removed. No-op when
// the floor is disabled.
func (d *daemon) pruneBelowThreshold(ctx context.Context) error {
	if d.cfg.minUpvotes <= 0 {
		return nil
	}
	res, err := d.db.ExecContext(ctx, `DELETE FROM suno.clips WHERE upvote_count < $1`, d.cfg.minUpvotes)
	if err != nil {
		return fmt.Errorf("prune below threshold: %w", err)
	}
	if n, _ := res.RowsAffected(); n > 0 {
		d.log.Info("pruned clips below upvote floor", "deleted", n, "floor", d.cfg.minUpvotes)
	}
	return nil
}

type creatorCursor struct {
	handle       string
	nextPage     int
	clipsIndexed int64
}

// pickCreators returns the next batch of creators to crawl, least-recently
// crawled first. Not-done creators rotate through the queue, one page each, so
// the walk advances breadth-first across every creator at once.
func pickCreators(ctx context.Context, db *sql.DB, limit int) ([]creatorCursor, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT handle, next_page, clips_indexed FROM suno.creators
		WHERE NOT done
		ORDER BY last_crawled_at ASC NULLS FIRST, discovered_at ASC
		LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var cs []creatorCursor
	for rows.Next() {
		var c creatorCursor
		if err := rows.Scan(&c.handle, &c.nextPage, &c.clipsIndexed); err != nil {
			return nil, err
		}
		cs = append(cs, c)
	}
	return cs, rows.Err()
}

// crawlCreatorsPass walks one page for each of a bounded number of creators,
// storing every qualifying clip and advancing each creator's page cursor.
func (d *daemon) crawlCreatorsPass(ctx context.Context) error {
	if d.cfg.creators <= 0 {
		return nil
	}
	cs, err := pickCreators(ctx, d.db, d.cfg.creators)
	if err != nil {
		return fmt.Errorf("pick creators: %w", err)
	}
	if len(cs) == 0 {
		return nil
	}
	fresh, stored, finished := 0, 0, 0
	for _, c := range cs {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		clips, pr, err := d.suno.fetchCreatorClips(ctx, c.handle, c.nextPage)
		if err != nil {
			d.log.Warn("creator crawl failed", "handle", c.handle, "page", c.nextPage, "err", err)
			_, _ = d.db.ExecContext(ctx, `
				UPDATE suno.creators
				SET failures = failures + 1,
				    done = failures + 1 >= 5,
				    last_error = $2,
				    last_crawled_at = now()
				WHERE handle = $1`, c.handle, err.Error())
			continue
		}
		got, gotFresh := 0, 0
		for _, raw := range clips {
			cf, perr := parseClip(raw)
			if perr != nil {
				continue
			}
			if !d.cfg.meetsThreshold(cf) {
				continue
			}
			var exists int
			_ = d.db.QueryRowContext(ctx, `SELECT 1 FROM suno.clips WHERE id=$1`, cf.ID).Scan(&exists)
			if serr := storeClip(ctx, d.db, cf, raw, "creator", 0); serr != nil {
				d.log.Warn("creator store failed", "id", cf.ID, "err", serr)
				continue
			}
			got++
			if exists == 0 {
				gotFresh++
			}
		}
		// The profile's public playlists are discovery edges: queue every one.
		for _, p := range pr.Playlists {
			if p.ID == "" || (p.IsPublic != nil && !*p.IsPublic) {
				continue
			}
			if (p.IsHidden != nil && *p.IsHidden) || (p.IsTrashed != nil && *p.IsTrashed) {
				continue
			}
			if qerr := d.queuePlaylist(ctx, playlistRef{id: p.ID, name: p.Name, userHandle: p.UserHandle, songCount: p.SongCount}); qerr != nil {
				d.log.Warn("playlist queue failed", "id", p.ID, "err", qerr)
			}
		}
		indexed := c.clipsIndexed + int64(got)
		done := len(clips) == 0 || (pr.NumTotalClips > 0 && indexed >= pr.NumTotalClips)
		if _, uerr := d.db.ExecContext(ctx, `
			UPDATE suno.creators SET
				user_id = CASE WHEN $2 <> '' THEN $2 ELSE user_id END,
				display_name = CASE WHEN $3 <> '' THEN $3 ELSE display_name END,
				total_clips = GREATEST(total_clips, $4),
				next_page = $5,
				clips_indexed = $6,
				failures = 0,
				done = $7,
				last_error = '',
				last_crawled_at = now()
			WHERE handle = $1`,
			c.handle, pr.UserID, pr.DisplayName, pr.NumTotalClips, c.nextPage+1, indexed, done); uerr != nil {
			d.log.Warn("creator cursor update failed", "handle", c.handle, "err", uerr)
		}
		stored += got
		fresh += gotFresh
		if done {
			finished++
		}
		time.Sleep(creatorDelay)
	}
	d.log.Info("creator crawl pass done",
		"creators", len(cs), "clips_stored", stored, "fresh", fresh, "finished", finished)
	return nil
}

// ------------------------------ Tag-search lane -----------------------------

// seedTags fills the tag queue from the styles sitemap. Runs at startup and is
// idempotent, so a restart with an already-seeded queue is a no-op.
func (d *daemon) seedTags(ctx context.Context) error {
	tags, err := d.suno.fetchStylesSitemap(ctx)
	if err != nil {
		return fmt.Errorf("styles sitemap: %w", err)
	}
	added := 0
	for _, tag := range tags {
		res, err := d.db.ExecContext(ctx, tagEnsure, tag)
		if err != nil {
			return fmt.Errorf("ensure tag %q: %w", tag, err)
		}
		if n, _ := res.RowsAffected(); n > 0 {
			added++
		}
	}
	d.log.Info("tag queue seeded", "style_tags", len(tags), "added", added)
	return nil
}

type tagCursor struct {
	tag       string
	nextIndex int
}

// pickTags returns the next batch of unfinished tags, least-recently crawled
// first, so the walk cycles through the vocabulary instead of hammering one tag.
func pickTags(ctx context.Context, db *sql.DB, limit int) ([]tagCursor, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT tag, next_index FROM suno.tags
		WHERE NOT done
		ORDER BY last_crawled_at ASC NULLS FIRST, discovered_at ASC
		LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var cs []tagCursor
	for rows.Next() {
		var c tagCursor
		if err := rows.Scan(&c.tag, &c.nextIndex); err != nil {
			return nil, err
		}
		cs = append(cs, c)
	}
	return cs, rows.Err()
}

// tagPass pulls one page per queued tag. With rank_by=upvote_count the page is
// winners-first, so a tag whose page tops out below the floor is marked done.
func (d *daemon) tagPass(ctx context.Context) error {
	if d.cfg.tagsPerPass <= 0 {
		return nil
	}
	cs, err := pickTags(ctx, d.db, d.cfg.tagsPerPass)
	if err != nil {
		return fmt.Errorf("pick tags: %w", err)
	}
	if len(cs) == 0 {
		return nil
	}
	stored, fresh, finished := 0, 0, 0
	for _, c := range cs {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		items, totalHits, err := d.suno.fetchTagPage(ctx, c.tag, c.nextIndex, d.cfg.tagPageSize)
		if err != nil {
			d.log.Warn("tag search failed", "tag", c.tag, "err", err)
			_, _ = d.db.ExecContext(ctx, `
				UPDATE suno.tags
				SET failures = failures + 1,
				    done = failures + 1 >= 5,
				    last_error = $2,
				    last_crawled_at = now()
				WHERE tag = $1`, c.tag, err.Error())
			continue
		}
		got, gotFresh, maxUp := 0, 0, int64(0)
		for _, raw := range items {
			cf, perr := parseClip(raw)
			if perr != nil {
				continue
			}
			if cf.UpvoteCount > maxUp {
				maxUp = cf.UpvoteCount
			}
			if !d.cfg.meetsThreshold(cf) {
				continue
			}
			var exists int
			_ = d.db.QueryRowContext(ctx, `SELECT 1 FROM suno.clips WHERE id=$1`, cf.ID).Scan(&exists)
			if serr := storeClip(ctx, d.db, cf, raw, "tag_search", 0); serr != nil {
				d.log.Warn("tag store failed", "id", cf.ID, "err", serr)
				continue
			}
			got++
			if exists == 0 {
				gotFresh++
			}
		}
		next, done := tagPageAdvance(int64(c.nextIndex), int64(len(items)), int64(totalHits), maxUp, int64(d.cfg.minUpvotes))
		if _, uerr := d.db.ExecContext(ctx, `
			UPDATE suno.tags SET
				next_index = $2,
				total_hits = GREATEST(total_hits, $3),
				clips_stored = clips_stored + $4,
				failures = 0,
				done = $5,
				last_error = '',
				last_crawled_at = now()
			WHERE tag = $1`, c.tag, next, totalHits, got, done); uerr != nil {
			d.log.Warn("tag cursor update failed", "tag", c.tag, "err", uerr)
		}
		stored += got
		fresh += gotFresh
		if done {
			finished++
		}
		time.Sleep(creatorDelay)
	}
	d.log.Info("tag search pass done",
		"tags", len(cs), "clips_stored", stored, "fresh", fresh, "finished", finished)
	return nil
}

// ------------------------------ Playlist lane -------------------------------

// queuePlaylist records a discovered playlist; callers may know only its id.
func (d *daemon) queuePlaylist(ctx context.Context, p playlistRef) error {
	if p.id == "" {
		return nil
	}
	_, err := d.db.ExecContext(ctx, playlistEnsure, p.id, p.name, p.userHandle, p.songCount)
	return err
}

type playlistCursor struct {
	id           string
	nextPage     int
	clipsIndexed int64
	songCount    int64
}

// pickPlaylists returns the next batch of unfinished playlists, least-recently
// crawled first.
func pickPlaylists(ctx context.Context, db *sql.DB, limit int) ([]playlistCursor, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT id, next_page, clips_indexed, song_count FROM suno.playlists
		WHERE NOT done
		ORDER BY last_crawled_at ASC NULLS FIRST, discovered_at ASC
		LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var cs []playlistCursor
	for rows.Next() {
		var c playlistCursor
		if err := rows.Scan(&c.id, &c.nextPage, &c.clipsIndexed, &c.songCount); err != nil {
			return nil, err
		}
		cs = append(cs, c)
	}
	return cs, rows.Err()
}

// playlistPass walks one page for each queued playlist. Each page yields FULL
// clip objects plus the owner handle (queued for the creator crawl), so
// playlists are both a clip source and a creator source.
func (d *daemon) playlistPass(ctx context.Context) error {
	if d.cfg.playlistsPerPass <= 0 {
		return nil
	}
	cs, err := pickPlaylists(ctx, d.db, d.cfg.playlistsPerPass)
	if err != nil {
		return fmt.Errorf("pick playlists: %w", err)
	}
	if len(cs) == 0 {
		return nil
	}
	stored, fresh, finished := 0, 0, 0
	for _, c := range cs {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		pr, err := d.suno.fetchPlaylistPage(ctx, c.id, c.nextPage)
		if err != nil {
			d.log.Warn("playlist fetch failed", "id", c.id, "page", c.nextPage, "err", err)
			_, _ = d.db.ExecContext(ctx, `
				UPDATE suno.playlists
				SET failures = failures + 1,
				    done = failures + 1 >= 5,
				    last_error = $2,
				    last_crawled_at = now()
				WHERE id = $1`, c.id, err.Error())
			continue
		}
		got, gotFresh, seen := 0, 0, 0
		for _, pc := range pr.PlaylistClips {
			seen++
			if len(pc.Clip) == 0 {
				continue
			}
			cf, perr := parseClip(pc.Clip)
			if perr != nil {
				continue
			}
			if !d.cfg.meetsThreshold(cf) {
				continue
			}
			var exists int
			_ = d.db.QueryRowContext(ctx, `SELECT 1 FROM suno.clips WHERE id=$1`, cf.ID).Scan(&exists)
			if serr := storeClip(ctx, d.db, cf, pc.Clip, "playlist", 0); serr != nil {
				d.log.Warn("playlist store failed", "id", cf.ID, "err", serr)
				continue
			}
			got++
			if exists == 0 {
				gotFresh++
			}
		}
		if pr.UserHandle != "" {
			_, _ = d.db.ExecContext(ctx, creatorEnsure, pr.UserHandle, "", "")
		}
		total := pr.NumTotal
		if total == 0 {
			total = pr.SongCount
		}
		if total == 0 {
			total = c.songCount
		}
		indexed := c.clipsIndexed + int64(got)
		done := seen == 0 || (total > 0 && int64(seen) >= total)
		if _, uerr := d.db.ExecContext(ctx, `
			UPDATE suno.playlists SET
				name = CASE WHEN $2 <> '' THEN $2 ELSE name END,
				user_handle = CASE WHEN $3 <> '' THEN $3 ELSE user_handle END,
				song_count = GREATEST(song_count, $4),
				next_page = $5,
				clips_indexed = $6,
				failures = 0,
				done = $7,
				last_error = '',
				last_crawled_at = now()
			WHERE id = $1`,
			c.id, pr.Name, pr.UserHandle, total, c.nextPage+1, indexed, done); uerr != nil {
			d.log.Warn("playlist cursor update failed", "id", c.id, "err", uerr)
		}
		stored += got
		fresh += gotFresh
		if done {
			finished++
		}
		time.Sleep(creatorDelay)
	}
	d.log.Info("playlist pass done",
		"playlists", len(cs), "clips_stored", stored, "fresh", fresh, "finished", finished)
	return nil
}

// -------------------------------- Seed lane ---------------------------------

type seedCursor struct {
	id     string
	source string
}

// pickSeeds returns queued one-shot ids, least-attempted first.
func pickSeeds(ctx context.Context, db *sql.DB, limit int) ([]seedCursor, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT id, source FROM suno.fetch_queue
		WHERE NOT done
		ORDER BY attempts ASC, discovered_at ASC
		LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var cs []seedCursor
	for rows.Next() {
		var c seedCursor
		if err := rows.Scan(&c.id, &c.source); err != nil {
			return nil, err
		}
		cs = append(cs, c)
	}
	return cs, rows.Err()
}

// seedPass fetches queued one-shot ids (contest base songs) by id and stores
// them through the normal quality gate. Three attempts, then the row is done.
func (d *daemon) seedPass(ctx context.Context) error {
	if d.cfg.seedsPerPass <= 0 {
		return nil
	}
	cs, err := pickSeeds(ctx, d.db, d.cfg.seedsPerPass)
	if err != nil {
		return fmt.Errorf("pick seeds: %w", err)
	}
	if len(cs) == 0 {
		return nil
	}
	fetched, stored := 0, 0
	for _, c := range cs {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		raw, err := d.suno.fetchClip(ctx, c.id)
		if err != nil {
			d.log.Warn("seed fetch failed", "id", c.id, "err", err)
			_, _ = d.db.ExecContext(ctx, `
				UPDATE suno.fetch_queue
				SET attempts = attempts + 1,
				    done = attempts + 1 >= 3,
				    last_error = $2,
				    fetched_at = now()
				WHERE id = $1`, c.id, err.Error())
			continue
		}
		fetched++
		cf, perr := parseClip(raw)
		if perr == nil && d.cfg.meetsThreshold(cf) {
			if serr := storeClip(ctx, d.db, cf, raw, c.source, 0); serr == nil {
				stored++
			}
		}
		_, _ = d.db.ExecContext(ctx, `
			UPDATE suno.fetch_queue SET done = true, last_error = '', fetched_at = now()
			WHERE id = $1`, c.id)
		time.Sleep(creatorDelay)
	}
	d.log.Info("seed pass done", "ids", len(cs), "fetched", fetched, "stored", stored)
	return nil
}

// ------------------------------ Editorial lane ------------------------------

// editorialPass refreshes the playlist queue from the public editorial indexes
// and queues contest base clips. suno.meta rate-limits the refresh to at most
// one run per editorialEvery interval, so restarts cannot hammer the indexes.
func (d *daemon) editorialPass(ctx context.Context) error {
	if d.cfg.editorialEvery <= 0 {
		return nil
	}
	var last sql.NullTime
	if err := d.db.QueryRowContext(ctx,
		`SELECT updated_at FROM suno.meta WHERE key = 'editorial_seed'`).Scan(&last); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("editorial meta: %w", err)
	}
	if last.Valid && time.Since(last.Time) < d.cfg.editorialEvery {
		return nil
	}
	refs, err := d.suno.fetchEditorial(ctx)
	if err != nil {
		return err
	}
	queued := 0
	for _, ref := range refs {
		if qerr := d.queuePlaylist(ctx, ref); qerr == nil {
			queued++
		}
	}
	seeds := 0
	if ids, cerr := d.suno.fetchContestSeeds(ctx); cerr != nil {
		d.log.Warn("contest seeds failed", "err", cerr)
	} else {
		for _, id := range ids {
			if id == "" {
				continue
			}
			res, ierr := d.db.ExecContext(ctx, seedEnsure, id, "contest")
			if ierr == nil {
				if n, _ := res.RowsAffected(); n > 0 {
					seeds++
				}
			}
		}
	}
	if _, err := d.db.ExecContext(ctx, `
		INSERT INTO suno.meta (key, value, updated_at) VALUES ('editorial_seed', 'ok', now())
		ON CONFLICT (key) DO UPDATE SET value = 'ok', updated_at = now()`); err != nil {
		return fmt.Errorf("editorial meta update: %w", err)
	}
	d.log.Info("editorial seed done", "playlist_refs", queued, "contest_seeds_queued", seeds)
	return nil
}

// jitter scales d by a random factor in [1-frac, 1+frac].
func jitter(d time.Duration, frac float64) time.Duration {
	if frac <= 0 {
		return d
	}
	n, err := rand.Int(rand.Reader, big.NewInt(2_000_001))
	if err != nil {
		return d
	}
	f := 1.0 - frac + (float64(n.Int64())/1_000_000.0-1.0)*frac
	return time.Duration(float64(d) * f)
}

func connectDB(ctx context.Context, cfg config, log *slog.Logger) (*sql.DB, error) {
	if cfg.databaseURL == "" {
		return nil, errors.New("no database URL: set SUNO_TOP_DATABASE_URL (or DATABASE_URL)")
	}
	db, err := sql.Open("postgres", cfg.databaseURL)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(2)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(time.Hour)
	deadline := time.Now().Add(2 * time.Minute)
	for {
		pctx, cancel := context.WithTimeout(ctx, cfg.dbTimeout)
		err = db.PingContext(pctx)
		cancel()
		if err == nil {
			return db, nil
		}
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("database unreachable: %w", err)
		}
		log.Warn("database ping failed (retrying)", "err", err)
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(5 * time.Second):
		}
	}
}

func main() {
	log := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	log.Info(appName + " starting")

	cfg := loadConfig(log)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	db, err := connectDB(ctx, cfg, log)
	if err != nil {
		log.Error("init failed", "err", err)
		os.Exit(1)
	}
	defer db.Close()

	d := &daemon{
		cfg: cfg,
		suno: &sunoClient{
			http: &http.Client{Timeout: cfg.httpTimeout},
			log:  log,
		},
		db:  db,
		log: log,
	}
	if err := d.ensureSchema(ctx); err != nil {
		log.Error("schema setup failed", "err", err)
		os.Exit(1)
	}
	if err := d.pruneBelowThreshold(ctx); err != nil {
		log.Warn("threshold prune failed", "err", err)
	}
	if err := d.seedCreators(ctx); err != nil {
		log.Warn("creator seed failed", "err", err)
	}
	if err := d.seedTags(ctx); err != nil {
		log.Warn("tag seed failed", "err", err)
	}

	runPass := func() {
		pctx, cancel := context.WithTimeout(ctx, cfg.httpTimeout*time.Duration(
			6+cfg.rechecks+cfg.creators+cfg.tagsPerPass+cfg.playlistsPerPass+cfg.seedsPerPass))
		defer cancel()
		if err := d.editorialPass(pctx); err != nil {
			log.Warn("editorial pass failed", "err", err)
		}
		if err := d.harvestPass(pctx); err != nil {
			log.Warn("harvest pass failed", "err", err)
		}
		if err := d.recheckPass(pctx); err != nil {
			log.Warn("recheck pass failed", "err", err)
		}
		if err := d.crawlCreatorsPass(pctx); err != nil {
			log.Warn("creator crawl pass failed", "err", err)
		}
		if err := d.tagPass(pctx); err != nil {
			log.Warn("tag search pass failed", "err", err)
		}
		if err := d.playlistPass(pctx); err != nil {
			log.Warn("playlist pass failed", "err", err)
		}
		if err := d.seedPass(pctx); err != nil {
			log.Warn("seed pass failed", "err", err)
		}
	}

	if cfg.once {
		runPass()
		log.Info(appName + " one-shot complete")
		return
	}

	// First pass immediately, then on the jittered ticker.
	runPass()
	for {
		wait := jitter(cfg.interval, cfg.jitterFrac)
		select {
		case <-ctx.Done():
			log.Info(appName + " shutting down")
			return
		case <-time.After(wait):
		}
		runPass()
	}
}
