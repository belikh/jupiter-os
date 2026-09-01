// Package db opens the router's SQLite database in WAL mode and applies
// embedded schema migrations.
package db

import (
	"database/sql"
	"embed"
	"fmt"
	"io/fs"
	"path/filepath"

	// Pure-Go SQLite driver (no cgo); its init registers the "sqlite"
	// driver with database/sql. The DSN below pins per-connection
	// pragmas so they hold on every pooled connection.
	_ "modernc.org/sqlite"
)

// migrationsFS holds the SQL migration files. Files are applied in lexical
// filename order; names must be zero-padded (0001_baseline.sql).
//
//go:embed migrations/*.sql
var migrationsFS embed.FS

// migrationsDir is the directory inside the migrations FS.
const migrationsDir = "migrations"

// pragmaDSN builds a DSN whose _pragma query parameters are executed on every
// pooled connection, not just the first. Journal mode and foreign key
// enforcement are per-connection settings in SQLite, so the DSN — not a
// one-shot Exec — is the only reliable place to pin them. busy_timeout comes
// first: the driver applies _pragma values in order, and journal_mode changes
// can hit SQLITE_BUSY before the timeout is in effect.
func pragmaDSN(path string) string {
	return fmt.Sprintf("file:%s?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=synchronous(1)&_pragma=foreign_keys(1)", filepath.ToSlash(path))
}

// Open opens (creating if necessary) the SQLite database at path, applies the
// WAL pragma set on every pooled connection, and runs any pending migrations.
func Open(path string) (*sql.DB, error) {
	sqlDB, err := sql.Open("sqlite", pragmaDSN(path))
	if err != nil {
		return nil, fmt.Errorf("open sqlite %s: %w", path, err)
	}

	if err := migrate(sqlDB, migrationsFS); err != nil {
		sqlDB.Close()
		return nil, fmt.Errorf("migrate %s: %w", path, err)
	}
	return sqlDB, nil
}

// migrate applies SQL migrations from src in lexical filename order. Applied
// migrations are recorded in schema_migrations; each file plus its record is
// committed in a single transaction, so a migration that fails part-way
// leaves no trace and is retried on the next Open.
func migrate(sqlDB *sql.DB, src fs.FS) error {
	if _, err := sqlDB.Exec(`CREATE TABLE IF NOT EXISTS schema_migrations (
		name TEXT PRIMARY KEY,
		applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
	)`); err != nil {
		return fmt.Errorf("create schema_migrations: %w", err)
	}

	entries, err := fs.ReadDir(src, migrationsDir)
	if err != nil {
		return fmt.Errorf("read migrations: %w", err)
	}

	for _, e := range entries {
		name := e.Name()
		var applied bool
		if err := sqlDB.QueryRow("SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE name = ?)", name).Scan(&applied); err != nil {
			return fmt.Errorf("check %s: %w", name, err)
		}
		if applied {
			continue
		}
		body, err := fs.ReadFile(src, migrationsDir+"/"+name)
		if err != nil {
			return fmt.Errorf("read %s: %w", name, err)
		}
		if err := applyMigration(sqlDB, name, string(body)); err != nil {
			return err
		}
	}
	return nil
}

// applyMigration runs one migration file and records it, both inside a single
// transaction: either the file's statements and its schema_migrations row
// commit together, or neither lands.
func applyMigration(sqlDB *sql.DB, name, body string) error {
	tx, err := sqlDB.Begin()
	if err != nil {
		return fmt.Errorf("begin %s: %w", name, err)
	}
	defer tx.Rollback() // no-op after Commit

	if _, err := tx.Exec(body); err != nil {
		return fmt.Errorf("apply %s: %w", name, err)
	}
	if _, err := tx.Exec("INSERT INTO schema_migrations (name) VALUES (?)", name); err != nil {
		return fmt.Errorf("record %s: %w", name, err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit %s: %w", name, err)
	}
	return nil
}
