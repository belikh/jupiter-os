// suno-backfill — one-shot longitudinal re-observation of a KNOWN id list
// against Suno's public clip endpoint, into the fleet Postgres (callisto, db
// `jupiter`, schema `suno`). Built for the arXiv 2509.11824 authors'
// released suno_urls list (81,434 songs scraped May–Oct 2024): one GET per
// id today turns the 2024 dumps into an engagement-in-2026 longitudinal
// corpus — which of those songs are 2026 winners, and with what accumulated
// counts. Companion to pkgs/suno-top: that daemon harvests what trends NOW;
// this one re-visits the fixed 2024 cohort.
//
// Lane: GET https://studio-api.prod.suno.com/api/clip/<id> — the same
// unauthenticated endpoint suno-top's recheck loop rides (verified live
// 2026-09-19).
//
// Floor (owner decision 2026-09-19): the corpus is winners-only, matching
// suno-top — only clips with upvote_count >= SUNO_BACKFILL_MIN_UPVOTES
// (default 100) are stored, landing directly in suno.clips via the same
// upsert suno-top uses, plus a suno.clip_sightings row with
// source='backfill_2024' so the cohort stays identifiable AND the running
// daemon's recheck loop starts maintaining growth curves for these winners
// with zero extra code. Nothing below the floor ever enters suno.clips, so
// the daemon's floor prune has nothing to clash with.
//
// Bookkeeping, not corpus: every processed id — winner, below-floor, or 404
// (link rot is itself a finding) — is recorded in the tiny
// suno.backfill_seen table purely so restarts skip it; a 31h run must not
// re-fetch 80k songs because sub-floor ids left no row. Summary counts are
// logged either way.
//
// Resume: each id commits before moving on; kill any time, at most the
// in-flight request is lost. 429 backs off 60s and retries (bounded);
// transport errors leave the id unrecorded for the next run.
//
// Politeness: single lane, default 1300ms ± 20% jitter between GETs —
// 81,434 ids ≈ 31h once. Not parallel by design.
//
// Usage:
//
//	SUNO_BACKFILL_DATABASE_URL=postgresql://suno:…@10.1.1.3:5432/jupiter?sslmode=disable \
//	  suno-backfill -ids suno_urls.csv [-limit 200] [-delay 1300ms]
//
// Input lines may be bare UUIDs or suno.com/song/<uuid> URLs; the header and
// non-matching lines are skipped. -limit N caps NEW ids processed this run
// (validation batches).
package main

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"os"
	"os/signal"
	"regexp"
	"strings"
	"syscall"
	"time"

	_ "github.com/lib/pq"
)

const (
	appName = "suno-backfill"

	apiBase  = "https://studio-api.prod.suno.com"
	clipPath = "/api/clip/"

	defaultUA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

	uuidPattern = `[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`
)

var uuidRe = regexp.MustCompile(uuidPattern)

type config struct {
	databaseURL string
	idsPath     string
	limit       int
	minUpvotes  int64
	delay       time.Duration
	httpTimeout time.Duration
	dbTimeout   time.Duration
}

func loadConfig(log *slog.Logger) (config, error) {
	cfg := config{}
	flag.StringVar(&cfg.idsPath, "ids", "", "path to file of ids (bare UUIDs or suno.com/song/<uuid> URLs; required)")
	flag.IntVar(&cfg.limit, "limit", 0, "cap on NEW ids processed this run (0 = no cap)")
	flag.Int64Var(&cfg.minUpvotes, "min-upvotes", 100, "upvote floor; below-floor clips are counted, not stored")
	flag.DurationVar(&cfg.delay, "delay", 1300*time.Millisecond, "base delay between GETs")
	flag.DurationVar(&cfg.httpTimeout, "http-timeout", 30*time.Second, "per-request timeout")
	flag.DurationVar(&cfg.dbTimeout, "db-timeout", 30*time.Second, "db dial/operation timeout")
	flag.Parse()
	cfg.databaseURL = os.Getenv("SUNO_BACKFILL_DATABASE_URL")
	if cfg.databaseURL == "" {
		cfg.databaseURL = os.Getenv("DATABASE_URL")
	}
	if cfg.databaseURL == "" {
		return cfg, errors.New("no database URL: set SUNO_BACKFILL_DATABASE_URL (or DATABASE_URL)")
	}
	if cfg.idsPath == "" {
		return cfg, errors.New("no id list: pass -ids <file>")
	}
	log.Info("config loaded", "ids", cfg.idsPath, "limit", cfg.limit,
		"min_upvotes", cfg.minUpvotes, "delay", cfg.delay, "http_timeout", cfg.httpTimeout)
	return cfg, nil
}

// ------------------------------- id ingestion -------------------------------

// loadIDs extracts a UUID from every line that carries one, de-duplicated,
// order-preserving.
func loadIDs(path string) ([]string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var ids []string
	seen := map[string]bool{}
	for _, line := range strings.Split(string(b), "\n") {
		m := uuidRe.FindString(line)
		if m == "" || seen[m] {
			continue
		}
		seen[m] = true
		ids = append(ids, m)
	}
	return ids, nil
}

// --------------------------------- Suno lane ---------------------------------

type sunoClient struct {
	http *http.Client
}

// fetchClip returns (body, nil) on 200, (nil, nil) on 404 (gone), and an
// error otherwise. 429s are retried with a 60s backoff (bounded).
func (c *sunoClient) fetchClip(ctx context.Context, id string) ([]byte, error) {
	for attempt := 0; ; attempt++ {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, apiBase+clipPath+id, nil)
		if err != nil {
			return nil, err
		}
		req.Header.Set("User-Agent", defaultUA)
		req.Header.Set("Origin", "https://suno.com")
		req.Header.Set("Referer", "https://suno.com/")
		resp, err := c.http.Do(req)
		if err != nil {
			return nil, err
		}
		switch {
		case resp.StatusCode == http.StatusOK:
			defer resp.Body.Close()
			return io.ReadAll(resp.Body)
		case resp.StatusCode == http.StatusNotFound:
			resp.Body.Close()
			return nil, nil
		case resp.StatusCode == http.StatusTooManyRequests && attempt < 3:
			resp.Body.Close()
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(60 * time.Second):
			}
			continue
		default:
			b, _ := io.ReadAll(io.LimitReader(resp.Body, 256))
			resp.Body.Close()
			return nil, fmt.Errorf("clip %s: status %d: %s", id, resp.StatusCode,
				strings.TrimSpace(string(b)))
		}
	}
}

// clipFields mirrors suno-top's projection of the clip object; the FULL
// object always travels in `raw`.
type clipFields struct {
	Title, Handle, DisplayName            string
	PlayCount, UpvoteCount, CommentCount  int64
	CreatedAt                             sql.NullTime
	MajorModelVersion, ModelName          string
	DurationSec                           sql.NullFloat64
	Tags, Prompt, StylePrompt, PromptMode string
	IsPublic, IsExplicit, IsRemix         *bool
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

func parseClip(body []byte) (clipFields, error) {
	var cf clipFields
	var top struct {
		Title               string       `json:"title"`
		Handle              *string      `json:"handle"`
		DisplayName         *string      `json:"display_name"`
		PlayCount           *int64       `json:"play_count"`
		UpvoteCount         *int64       `json:"upvote_count"`
		CommentCount        *int64       `json:"comment_count"`
		CreatedAt           *string      `json:"created_at"`
		MajorModelVersion   *string      `json:"major_model_version"`
		ModelName           *string      `json:"model_name"`
		IsPublic            *bool        `json:"is_public"`
		Explicit            *bool        `json:"explicit"`
		Metadata            clipMetadata `json:"metadata"`
	}
	if err := json.Unmarshal(body, &top); err != nil {
		return cf, fmt.Errorf("unmarshal clip: %w", err)
	}
	derefStr := func(p *string) string {
		if p == nil {
			return ""
		}
		return *p
	}
	derefI := func(p *int64) int64 {
		if p == nil {
			return 0
		}
		return *p
	}
	cf.Title = top.Title
	cf.Handle = derefStr(top.Handle)
	cf.DisplayName = derefStr(top.DisplayName)
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
	cf.Prompt = derefStr(top.Metadata.Prompt)
	cf.StylePrompt = derefStr(top.Metadata.GptDescriptionPrompt)
	if top.Metadata.Type != nil {
		cf.PromptMode = strings.ToLower(*top.Metadata.Type)
	} else if top.Metadata.Task != nil {
		cf.PromptMode = strings.ToLower(*top.Metadata.Task)
	}
	return cf, nil
}

// --------------------------------- Storage ----------------------------------

// Bookkeeping table (resume only — never part of the research corpus):
// one row per processed id, whatever the outcome. Winners additionally land
// in suno.clips/suno.clip_sightings via the suno-top-shaped upserts below.
const schemaDDL = `
CREATE TABLE IF NOT EXISTS suno.backfill_seen (
	id         text PRIMARY KEY,
	status     text NOT NULL,   -- 'winner' | 'below_floor' | 'gone404'
	fetched_at timestamptz NOT NULL DEFAULT now()
);
`

// Verbatim shape of suno-top's clipUpsert (minus the recheck bookkeeping,
// which is not ours to touch): keeps every column the daemon expects to
// maintain, so its recheck loop adopts backfilled winners seamlessly.
const clipUpsert = `
INSERT INTO suno.clips (
	id, title, handle, display_name, user_id,
	play_count, upvote_count, comment_count, created_at,
	major_model_version, model_name, duration_sec,
	tags, prompt, style_prompt, prompt_mode,
	is_public, is_explicit, is_remix, raw
) VALUES (
	$1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20
)
ON CONFLICT (id) DO UPDATE SET
	title               = EXCLUDED.title,
	handle              = EXCLUDED.handle,
	display_name        = EXCLUDED.display_name,
	user_id             = COALESCE(EXCLUDED.user_id, suno.clips.user_id),
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
	raw                 = EXCLUDED.raw
`

const sightingInsert = `
INSERT INTO suno.clip_sightings
	(clip_id, source, trending_rank, play_count, upvote_count, comment_count)
VALUES ($1, 'backfill_2024', NULL, $2, $3, $4)
`

func storeWinner(ctx context.Context, db *sql.DB, id string, cf clipFields, raw []byte) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck — commit below owns the outcome

	if _, err := tx.ExecContext(ctx, clipUpsert,
		id, cf.Title, cf.Handle, cf.DisplayName, "",
		cf.PlayCount, cf.UpvoteCount, cf.CommentCount, cf.CreatedAt,
		cf.MajorModelVersion, cf.ModelName, cf.DurationSec,
		cf.Tags, cf.Prompt, cf.StylePrompt, cf.PromptMode,
		cf.IsPublic, cf.IsExplicit, cf.IsRemix, raw,
	); err != nil {
		return fmt.Errorf("upsert clip: %w", err)
	}
	if _, err := tx.ExecContext(ctx, sightingInsert,
		id, cf.PlayCount, cf.UpvoteCount, cf.CommentCount,
	); err != nil {
		return fmt.Errorf("insert sighting: %w", err)
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO suno.backfill_seen (id, status) VALUES ($1, 'winner') ON CONFLICT (id) DO NOTHING`, id,
	); err != nil {
		return fmt.Errorf("insert seen: %w", err)
	}
	return tx.Commit()
}

func storeSeen(ctx context.Context, db *sql.DB, id, status string) error {
	_, err := db.ExecContext(ctx,
		`INSERT INTO suno.backfill_seen (id, status) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING`,
		id, status)
	return err
}

func loadDone(ctx context.Context, db *sql.DB) (map[string]bool, error) {
	rows, err := db.QueryContext(ctx, `SELECT id FROM suno.backfill_seen`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	done := map[string]bool{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		done[id] = true
	}
	return done, rows.Err()
}

// ---------------------------------- Runtime ---------------------------------

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

func main() {
	log := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	log.Info(appName + " starting")

	cfg, err := loadConfig(log)
	if err != nil {
		log.Error("init failed", "err", err)
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	db, err := sql.Open("postgres", cfg.databaseURL)
	if err != nil {
		log.Error("db open failed", "err", err)
		os.Exit(1)
	}
	defer db.Close()
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(time.Hour)
	pctx, cancel := context.WithTimeout(ctx, cfg.dbTimeout)
	err = db.PingContext(pctx)
	cancel()
	if err != nil {
		log.Error("db unreachable", "err", err)
		os.Exit(1)
	}
	pctx, cancel = context.WithTimeout(ctx, cfg.dbTimeout)
	_, err = db.ExecContext(pctx, schemaDDL)
	cancel()
	if err != nil {
		log.Error("schema setup failed", "err", err)
		os.Exit(1)
	}

	ids, err := loadIDs(cfg.idsPath)
	if err != nil {
		log.Error("id list load failed", "err", err)
		os.Exit(1)
	}
	done, err := loadDone(ctx, db)
	if err != nil {
		log.Error("resume preload failed", "err", err)
		os.Exit(1)
	}
	log.Info("id list loaded", "total", len(ids), "already_done", len(done))

	client := &sunoClient{http: &http.Client{Timeout: cfg.httpTimeout}}

	var processed, winners, belowFloor, gone, errs int
	start := time.Now()
	for _, id := range ids {
		if ctx.Err() != nil {
			log.Info("signal received — stopping cleanly")
			break
		}
		if done[id] {
			continue
		}
		if cfg.limit > 0 && processed >= cfg.limit {
			log.Info("limit reached — stopping", "limit", cfg.limit)
			break
		}

		body, err := client.fetchClip(ctx, id)
		if err != nil {
			errs++
			log.Warn("fetch failed (left for next run)", "id", id, "err", err)
			select {
			case <-ctx.Done():
			case <-time.After(jitter(cfg.delay, 0.2)):
			}
			continue
		}
		processed++

		if body == nil { // 404 — link rot
			gone++
			ictx, cancel := context.WithTimeout(ctx, cfg.dbTimeout)
			err = storeSeen(ictx, db, id, "gone404")
			cancel()
			if err != nil {
				errs++
				log.Warn("store gone failed (left for next run)", "id", id, "err", err)
			}
		} else {
			cf, err := parseClip(body)
			if err != nil {
				errs++
				log.Warn("parse failed (left for next run)", "id", id, "err", err)
				continue
			}
			if cf.UpvoteCount < cfg.minUpvotes {
				belowFloor++
				ictx, cancel := context.WithTimeout(ctx, cfg.dbTimeout)
				err = storeSeen(ictx, db, id, "below_floor")
				cancel()
				if err != nil {
					errs++
					log.Warn("store below-floor failed (left for next run)", "id", id, "err", err)
				}
			} else {
				winners++
				ictx, cancel := context.WithTimeout(ctx, cfg.dbTimeout)
				err = storeWinner(ictx, db, id, cf, body)
				cancel()
				if err != nil {
					errs++
					log.Warn("store winner failed (left for next run)", "id", id, "err", err)
				}
			}
		}

		if processed%200 == 0 {
			elapsed := time.Since(start)
			rate := elapsed / time.Duration(processed)
			remain := len(done) + processed
			log.Info("progress",
				"processed", processed, "winners", winners, "below_floor", belowFloor,
				"gone", gone, "errors", errs, "per_item", rate.String(),
				"list_position", remain)
		}
		select {
		case <-ctx.Done():
		case <-time.After(jitter(cfg.delay, 0.2)):
		}
	}

	elapsed := time.Since(start)
	log.Info("run complete",
		"processed", processed, "winners", winners, "below_floor", belowFloor,
		"gone", gone, "errors", errs, "elapsed", elapsed.String())
}
