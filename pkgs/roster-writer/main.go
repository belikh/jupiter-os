package main

// main.go — roster-writer daemon (spec §8.1/§8.2): the sole writer for the
// roster domain. One pass = fetch the Kronos iCal feed, parse it with n8n
// parity (roster.go), write the canonical Postgres tables, publish the
// retained MQTT contract HA consumes, and record the feed state + detected
// changes. Config via environment (secrets injected by the systemd unit from
// sops files — never into the store).

import (
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"time"

	_ "github.com/lib/pq"
)

type config struct {
	icalURL      string
	databaseURL  string
	mqttURL      string
	interval     time.Duration
	objectID     string
	discoveryPre string
	topicBase    string
	once         bool
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func loadConfig() (config, error) {
	c := config{
		icalURL:      os.Getenv("ROSTER_ICAL_URL"),
		databaseURL:  os.Getenv("ROSTER_DATABASE_URL"),
		mqttURL:      os.Getenv("ROSTER_MQTT_URL"),
		objectID:     env("ROSTER_OBJECT_ID", "next_shift_roster"),
		discoveryPre: env("ROSTER_DISCOVERY_PREFIX", "homeassistant"),
		topicBase:    env("ROSTER_TOPIC_BASE", "jupiter/schedule/shift"),
		once:         os.Getenv("ROSTER_ONCE") == "1",
	}
	switch {
	case c.icalURL == "":
		return c, fmt.Errorf("ROSTER_ICAL_URL is required")
	case c.databaseURL == "":
		return c, fmt.Errorf("ROSTER_DATABASE_URL is required")
	case c.mqttURL == "":
		return c, fmt.Errorf("ROSTER_MQTT_URL is required")
	}
	iv, err := time.ParseDuration(env("ROSTER_INTERVAL", "15m"))
	if err != nil || iv <= 0 {
		return c, fmt.Errorf("ROSTER_INTERVAL invalid: %v", err)
	}
	c.interval = iv
	return c, nil
}

var httpClient = &http.Client{Timeout: 45 * time.Second}

func fetchICS(url string) (string, error) {
	resp, err := httpClient.Get(url)
	if err != nil {
		return "", fmt.Errorf("fetch: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("fetch: HTTP %d", resp.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if err != nil {
		return "", fmt.Errorf("read: %w", err)
	}
	return string(b), nil
}

func ensureSchema(db *sql.DB) error {
	_, err := db.Exec(`
CREATE TABLE IF NOT EXISTS public.roster_feed_state (
  only_row boolean PRIMARY KEY DEFAULT true CHECK (only_row),
  ics_raw text,
  content_hash text,
  fetched_at timestamptz,
  changes_detected integer NOT NULL DEFAULT 0
)`)
	return err
}

func readFeedState(db *sql.DB) (raw string, err error) {
	err = db.QueryRow(`SELECT coalesce(ics_raw,'') FROM public.roster_feed_state WHERE only_row`).Scan(&raw)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return raw, err
}

// writeRoster mirrors the n8n roster writer: replace the table, refresh
// history, log changes, update feed state — all in one transaction.
func writeRoster(db *sql.DB, raw string, rows []RosterRow, changes []Change, now time.Time) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := tx.Exec(`DELETE FROM public.shift_roster`); err != nil {
		return fmt.Errorf("clear roster: %w", err)
	}
	for _, r := range rows {
		var end any
		if r.EndISO != nil {
			end = r.EndISO.UTC()
		}
		if _, err := tx.Exec(`
INSERT INTO public.shift_roster (shift_date, start_utc, end_utc, is_next, source, ingested_at, location)
VALUES ($1,$2,$3,$4,'roster-writer',$5,$6)`,
			r.Date, r.StartISO.UTC(), end, r.IsNext, now.UTC(), r.Location); err != nil {
			return fmt.Errorf("insert roster %s: %w", r.Date, err)
		}
		if r.Category == "shift" {
			if _, err := tx.Exec(`
INSERT INTO public.shift_history (shift_date, start_utc) VALUES ($1,$2)
ON CONFLICT (shift_date, start_utc) DO NOTHING`, r.Date, r.StartISO.UTC()); err != nil {
				return fmt.Errorf("history %s: %w", r.Date, err)
			}
		}
	}
	for _, c := range changes {
		if _, err := tx.Exec(`
INSERT INTO public.shift_change_log (shift_date, detected_at, old_start, new_start)
VALUES ($1,$2,$3,$4)`, c.Date, now.UTC(), c.OldStart, c.NewStart); err != nil {
			return fmt.Errorf("change log %s: %w", c.Date, err)
		}
	}
	sum := sha256.Sum256([]byte(raw))
	if _, err := tx.Exec(`
INSERT INTO public.roster_feed_state (only_row, ics_raw, content_hash, fetched_at, changes_detected)
VALUES (true,$1,$2,$3,$4)
ON CONFLICT (only_row) DO UPDATE SET ics_raw=EXCLUDED.ics_raw,
  content_hash=EXCLUDED.content_hash, fetched_at=EXCLUDED.fetched_at,
  changes_detected=EXCLUDED.changes_detected`,
		raw, hex.EncodeToString(sum[:]), now.UTC(), len(changes)); err != nil {
		return fmt.Errorf("feed state: %w", err)
	}
	return tx.Commit()
}

func pass(cfg config, db *sql.DB, mq *mqttPublisher) error {
	now := time.Now()
	raw, err := fetchICS(cfg.icalURL)
	if err != nil {
		return err
	}
	rrows := sortedRows(parseRoster(raw), now)
	contract := computeContract(rrows, now)
	prevRaw, err := readFeedState(db)
	if err != nil {
		return fmt.Errorf("feed state read: %w", err)
	}
	changes := detectChanges(prevRaw, raw, now)
	if err := writeRoster(db, raw, rrows, changes, now); err != nil {
		return err
	}
	if err := mq.publishContract(cfg, contract, now); err != nil {
		return fmt.Errorf("mqtt: %w", err)
	}
	cf, _ := json.Marshal(contract)
	log.Printf("pass ok: rows=%d next=%s changes=%d contract=%s", len(rrows), contract.State, len(changes), string(cf))
	return nil
}

func main() {
	log.SetPrefix("roster-writer ")
	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("config: %v", err)
	}
	db, err := sql.Open("postgres", cfg.databaseURL)
	if err != nil {
		log.Fatalf("db open: %v", err)
	}
	defer db.Close()
	db.SetMaxOpenConns(2)
	if err := ensureSchema(db); err != nil {
		log.Fatalf("schema: %v", err)
	}
	mq, err := newMQTTPublisher(cfg.mqttURL)
	if err != nil {
		log.Fatalf("mqtt: %v", err)
	}
	defer mq.close()

	for {
		if err := pass(cfg, db, mq); err != nil {
			log.Printf("pass failed: %v", err) // keep looping; a feed blip must not kill the writer
		}
		if cfg.once {
			return
		}
		time.Sleep(cfg.interval)
	}
}
