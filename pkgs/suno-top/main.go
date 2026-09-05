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
//
// Deliberately NOT used: POST /api/feed/v3 (401 unauthenticated) and POST
// /api/unified/search/omnisearch (401) — both need the Clerk session. This
// daemon runs credential-free by design; suno-backup owns the cookie lane.
//
// Storage shape (schema `suno`, DDL idempotent, applied on start):
//   suno.clips         one row per unique clip; raw jsonb keeps the COMPLETE
//                      clip object verbatim; convenience columns (play_count,
//                      tags, prompt, lyrics, style_prompt, …) are projections.
//   suno.clip_sightings  append-only observation log: every trending sighting
//                      (with its 1-based feed rank — the recommendation
//                      algorithm's opinion, unrecoverable later) and every
//                      recheck where counts changed. This table IS the
//                      time-series: velocity curves, rotation re-promotions,
//                      trending-rank history.
//
// Politeness budget (defaults): one discovery POST per interval (3m → 480/day)
// plus up to 20 recheck GETs per pass with a 45m per-clip min-age (~19k/day
// worst case, realistically far less). All single small JSON requests — one
// browser tab's worth of traffic. Dial SUNO_TOP_RECHECKS=0 to disable
// rechecks entirely; raise INTERVAL to slow everything down.
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
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	_ "github.com/lib/pq"
)

const (
	appName = "suno-top"

	apiBase  = "https://studio-api.prod.suno.com"
	feedPath = "/api/unified/feed"
	clipPath = "/api/clip/"

	defaultUA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

	// The feed has never returned more than 25 items/page regardless of
	// page_size (verified 2026-09-04); larger values yield EMPTY pages, so
	// this is both the default and the hard cap.
	pageSizeCap = 25
)

type config struct {
	databaseURL   string
	interval      time.Duration
	pageSize      int
	rechecks      int
	recheckMinAge time.Duration
	jitterFrac    float64
	once          bool
	httpTimeout   time.Duration
	dbTimeout     time.Duration
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
	cfg := config{
		databaseURL:   os.Getenv("SUNO_TOP_DATABASE_URL"),
		interval:      getd("SUNO_TOP_INTERVAL", 3*time.Minute),
		pageSize:      ps,
		rechecks:      geti("SUNO_TOP_RECHECKS", 20),
		recheckMinAge: getd("SUNO_TOP_RECHECK_MIN_AGE", 45*time.Minute),
		jitterFrac:    getf("SUNO_TOP_JITTER", 0.15),
		once:          os.Getenv("SUNO_TOP_ONCE") == "1",
		httpTimeout:   getd("SUNO_TOP_HTTP_TIMEOUT", 30*time.Second),
		dbTimeout:     getd("SUNO_TOP_DB_TIMEOUT", 30*time.Second),
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
	Prompt                *string `json:"prompt"`
	Tags                  *string `json:"tags"`
	GptDescriptionPrompt  *string `json:"gpt_description_prompt"`
	Duration              *float64 `json:"duration"`
	Type                  *string `json:"type"`
	Task                  *string `json:"task"`
	IsRemix               *bool   `json:"is_remix"`
}

func parseClip(raw json.RawMessage) (clipFields, error) {
	var cf clipFields
	var top struct {
		ID                string  `json:"id"`
		Title             string  `json:"title"`
		Handle            *string `json:"handle"`
		DisplayName       *string `json:"display_name"`
		UserID            *string `json:"user_id"`
		PlayCount         *int64  `json:"play_count"`
		UpvoteCount       *int64  `json:"upvote_count"`
		CommentCount      *int64  `json:"comment_count"`
		CreatedAt         *string `json:"created_at"`
		MajorModelVersion *string `json:"major_model_version"`
		ModelName         *string `json:"model_name"`
		IsPublic          *bool   `json:"is_public"`
		Explicit          *bool   `json:"explicit"`
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

CREATE TABLE IF NOT EXISTS suno.clip_sightings (
	id            bigserial PRIMARY KEY,
	clip_id       text NOT NULL REFERENCES suno.clips(id) ON DELETE CASCADE,
	seen_at       timestamptz NOT NULL DEFAULT now(),
	source        text NOT NULL,           -- 'trending' | 'recheck'
	trending_rank integer,                 -- 1-based position in the feed, NULL for rechecks
	play_count    bigint NOT NULL,
	upvote_count  bigint NOT NULL,
	comment_count bigint NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS suno_clip_sightings_clip_idx ON suno.clip_sightings (clip_id, seen_at);
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
func pickRechecks(ctx context.Context, db *sql.DB, limit int, minAge time.Duration) ([]string, error) {
	rows, err := db.QueryContext(ctx, `
		SELECT id FROM suno.clips
		WHERE (last_rechecked_at IS NULL OR now() - last_rechecked_at > $1)
		ORDER BY play_count DESC
		LIMIT $2`, minAge, limit)
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
		if err := storeClip(ctx, d.db, cf, raw, "recheck", 0); err != nil {
			d.log.Warn("recheck store failed", "id", id, "err", err)
			continue
		}
		updated++
	}
	d.log.Info("recheck pass done", "polled", len(ids), "stored", updated)
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

	runPass := func() {
		pctx, cancel := context.WithTimeout(ctx, cfg.httpTimeout*time.Duration(2+cfg.rechecks))
		defer cancel()
		if err := d.harvestPass(pctx); err != nil {
			log.Warn("harvest pass failed", "err", err)
		}
		if err := d.recheckPass(pctx); err != nil {
			log.Warn("recheck pass failed", "err", err)
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
