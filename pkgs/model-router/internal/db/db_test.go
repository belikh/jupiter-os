package db

import (
	"context"
	"path/filepath"
	"testing"
	"testing/fstest"
)

var ctx = context.Background()

// TestOpenAppliesWAL is the Task 1 contract test from the brief: opening a
// database in a temp dir must leave it in WAL mode with synchronous=NORMAL.
func TestOpenAppliesWAL(t *testing.T) {
	d := t.TempDir()
	sqlDB, err := Open(filepath.Join(d, "router.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer sqlDB.Close()
	var mode string
	sqlDB.QueryRow("PRAGMA journal_mode").Scan(&mode)
	if mode != "wal" {
		t.Fatalf("journal_mode = %q, want wal", mode)
	}
	var sync int
	sqlDB.QueryRow("PRAGMA synchronous").Scan(&sync)
	if sync != 1 {
		t.Fatalf("synchronous = %d, want 1 (NORMAL)", sync)
	}
}

// TestOpenSetsBusyTimeout asserts the busy_timeout pragma is at least 5000ms
// so concurrent writers queue instead of failing immediately.
func TestOpenSetsBusyTimeout(t *testing.T) {
	d := t.TempDir()
	sqlDB, err := Open(filepath.Join(d, "router.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer sqlDB.Close()
	var timeout int
	if err := sqlDB.QueryRow("PRAGMA busy_timeout").Scan(&timeout); err != nil {
		t.Fatal(err)
	}
	if timeout < 5000 {
		t.Fatalf("busy_timeout = %d, want >= 5000", timeout)
	}
}

// TestOpenEnforcesForeignKeys asserts foreign_keys=on — the migrations and
// later tasks rely on referential integrity being enforced.
func TestOpenEnforcesForeignKeys(t *testing.T) {
	d := t.TempDir()
	sqlDB, err := Open(filepath.Join(d, "router.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer sqlDB.Close()
	var fk int
	if err := sqlDB.QueryRow("PRAGMA foreign_keys").Scan(&fk); err != nil {
		t.Fatal(err)
	}
	if fk != 1 {
		t.Fatalf("foreign_keys = %d, want 1 (on)", fk)
	}
}

// TestOpenPragmasHoldAcrossPooledConnections asserts the pragmas are set on
// every pooled connection, not just the first one. The first *sql.Conn is
// held open before the second is grabbed — otherwise the pool simply hands
// back the same idle connection and the test would pass even under a broken
// one-shot-Exec implementation. Raw exposes the underlying driver
// connections so the test can prove the two are genuinely distinct.
func TestOpenPragmasHoldAcrossPooledConnections(t *testing.T) {
	d := t.TempDir()
	sqlDB, err := Open(filepath.Join(d, "router.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer sqlDB.Close()

	// Hold the first connection open so the pool cannot reuse it below.
	first, err := sqlDB.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()

	var firstRaw any
	if err := first.Raw(func(c any) error { firstRaw = c; return nil }); err != nil {
		t.Fatal(err)
	}

	second, err := sqlDB.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()

	var secondRaw any
	if err := second.Raw(func(c any) error { secondRaw = c; return nil }); err != nil {
		t.Fatal(err)
	}
	if firstRaw == secondRaw {
		t.Fatal("failed to force a fresh pooled connection: both Conn calls returned the same underlying driver connection, so the pragma assertions below prove nothing")
	}

	var mode string
	if err := second.QueryRowContext(ctx, "PRAGMA journal_mode").Scan(&mode); err != nil {
		t.Fatal(err)
	}
	if mode != "wal" {
		t.Fatalf("second connection journal_mode = %q, want wal", mode)
	}
	var fk int
	if err := second.QueryRowContext(ctx, "PRAGMA foreign_keys").Scan(&fk); err != nil {
		t.Fatal(err)
	}
	if fk != 1 {
		t.Fatalf("second connection foreign_keys = %d, want 1 (on)", fk)
	}
	var sync int
	if err := second.QueryRowContext(ctx, "PRAGMA synchronous").Scan(&sync); err != nil {
		t.Fatal(err)
	}
	if sync != 1 {
		t.Fatalf("second connection synchronous = %d, want 1 (NORMAL)", sync)
	}
}

// TestOpenRunsMigrations asserts the initial migration ran: the migrations
// bookkeeping table and the schema baseline (meta) both exist.
func TestOpenRunsMigrations(t *testing.T) {
	d := t.TempDir()
	sqlDB, err := Open(filepath.Join(d, "router.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer sqlDB.Close()

	var count int
	if err := sqlDB.QueryRow("SELECT COUNT(*) FROM schema_migrations").Scan(&count); err != nil {
		t.Fatalf("schema_migrations missing: %v", err)
	}
	if count < 1 {
		t.Fatalf("schema_migrations rows = %d, want >= 1", count)
	}

	// The baseline schema must contain the meta key/value table.
	if _, err := sqlDB.Exec("INSERT INTO meta (key, value) VALUES ('probe', 'ok')"); err != nil {
		t.Fatalf("meta table missing or unusable: %v", err)
	}
	var value string
	if err := sqlDB.QueryRow("SELECT value FROM meta WHERE key = 'probe'").Scan(&value); err != nil {
		t.Fatal(err)
	}
	if value != "ok" {
		t.Fatalf("meta round-trip value = %q, want ok", value)
	}
}

// TestMigrateFailingMigrationRollsBack asserts a migration that fails
// part-way applies nothing and is retried on the next Open: each migration
// file and its schema_migrations record commit atomically, so the database
// never keeps a half-applied migration.
func TestMigrateFailingMigrationRollsBack(t *testing.T) {
	d := t.TempDir()
	path := filepath.Join(d, "router.db")

	// Baseline first, then a migration whose second statement is invalid SQL:
	// the CREATE TABLE must roll back along with the failure.
	sqlDB, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := sqlDB.Close(); err != nil {
		t.Fatal(err)
	}

	broken := fstest.MapFS{
		"migrations/0001_baseline.sql":      {Data: nil}, // already applied above; skipped
		"migrations/0002_provider_keys.sql": {Data: nil}, // already applied above; skipped
		"migrations/0009_broken.sql":        {Data: []byte("CREATE TABLE rolled (k TEXT); THIS IS NOT SQL;")},
	}
	reopened, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()

	if err := migrate(reopened, broken); err == nil {
		t.Fatal("migrate with a broken migration returned nil, want error")
	}

	// The failed migration left no trace: no record, no partial table.
	var count int
	if err := reopened.QueryRow("SELECT COUNT(*) FROM schema_migrations WHERE name = '0009_broken.sql'").Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 0 {
		t.Fatalf("schema_migrations records the failed migration (rows = %d, want 0)", count)
	}
	if _, err := reopened.Exec("SELECT * FROM rolled"); err == nil {
		t.Fatal("table 'rolled' survived the failed migration; the transaction did not roll back")
	}

	// And the next migrate call retries it cleanly — after fixing the body it
	// applies and is recorded exactly once.
	fixed := fstest.MapFS{
		"migrations/0001_baseline.sql":      {Data: nil},
		"migrations/0002_provider_keys.sql": {Data: nil},
		"migrations/0009_broken.sql":        {Data: []byte("CREATE TABLE rolled (k TEXT);")},
	}
	if err := migrate(reopened, fixed); err != nil {
		t.Fatal(err)
	}
	var recorded int
	if err := reopened.QueryRow("SELECT COUNT(*) FROM schema_migrations WHERE name = '0009_broken.sql'").Scan(&recorded); err != nil {
		t.Fatal(err)
	}
	if recorded != 1 {
		t.Fatalf("retried migration rows = %d, want 1", recorded)
	}
	if _, err := reopened.Exec("INSERT INTO rolled (k) VALUES ('probe')"); err != nil {
		t.Fatalf("table 'rolled' unusable after retry: %v", err)
	}
}

// TestOpenIsIdempotent asserts opening the same path twice applies migrations
// exactly once (no duplicate rows, no errors).
func TestOpenIsIdempotent(t *testing.T) {
	d := t.TempDir()
	path := filepath.Join(d, "router.db")

	sqlDB1, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	sqlDB1.Close()

	sqlDB2, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer sqlDB2.Close()

	var count int
	if err := sqlDB2.QueryRow("SELECT COUNT(*) FROM schema_migrations").Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 3 {
		t.Fatalf("schema_migrations rows = %d, want 3", count)
	}
}

// TestProviderKeysMigration asserts migration 0002 created the vault's
// provider_keys table with the shape the vault package inserts into.
func TestProviderKeysMigration(t *testing.T) {
	d := t.TempDir()
	sqlDB, err := Open(filepath.Join(d, "router.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer sqlDB.Close()

	if _, err := sqlDB.Exec(`INSERT INTO provider_keys (provider_id, key_alias, nonce, ciphertext, status, last_checked_at, detail)
		VALUES ('probe-provider', 'default', X'00000000000000000000000000000000', X'00000000000000000000000000000000', 'untested', NULL, NULL)`); err != nil {
		t.Fatalf("provider_keys unusable: %v", err)
	}

	var status string
	if err := sqlDB.QueryRow("SELECT status FROM provider_keys WHERE provider_id = 'probe-provider' AND key_alias = 'default'").Scan(&status); err != nil {
		t.Fatal(err)
	}
	if status != "untested" {
		t.Fatalf("status round-trip = %q, want untested", status)
	}

	// provider_id is the primary key: a second row for the same provider fails.
	if _, err := sqlDB.Exec(`INSERT INTO provider_keys (provider_id, nonce, ciphertext, status)
		VALUES ('probe-provider', X'00', X'00', 'untested')`); err == nil {
		t.Fatal("provider_keys accepted duplicate provider_id; PRIMARY KEY not enforced")
	}

	// The migration is recorded in schema_migrations.
	var recorded int
	if err := sqlDB.QueryRow("SELECT COUNT(*) FROM schema_migrations WHERE name = '0002_provider_keys.sql'").Scan(&recorded); err != nil {
		t.Fatal(err)
	}
	if recorded != 1 {
		t.Fatalf("0002 rows in schema_migrations = %d, want 1", recorded)
	}
}
