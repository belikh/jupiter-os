package vault

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"modelrouter/internal/db"
)

// newTestVault opens the router database in a temp dir with a random 32-byte
// master key and a Vault over it. The sql.DB stays open for direct-row
// assertions and is closed via the returned func.
func newTestVault(t *testing.T) (*Vault, func()) {
	t.Helper()
	sqlDB, err := db.Open(filepath.Join(t.TempDir(), "router.db"))
	if err != nil {
		t.Fatal(err)
	}
	master := make([]byte, 32)
	if _, err := rand.Read(master); err != nil {
		t.Fatal(err)
	}
	v, err := Open(sqlDB, master)
	if err != nil {
		sqlDB.Close()
		t.Fatal(err)
	}
	return v, func() { sqlDB.Close() }
}

// TestPutGetRoundTrip is the core vault contract: a stored key comes back
// byte-identical, and a missing key reports ok=false with no error.
func TestPutGetRoundTrip(t *testing.T) {
	v, done := newTestVault(t)
	defer done()

	secret := "sk-router-test-abcdef0123456789"
	if err := v.Put("openrouter", "default", secret); err != nil {
		t.Fatalf("Put: %v", err)
	}
	got, ok, err := v.Get("openrouter", "default")
	if err != nil || !ok {
		t.Fatalf("Get = (%q, %v, %v), want (secret, true, nil)", got, ok, err)
	}
	if got != secret {
		t.Fatalf("Get = %q, want %q", got, secret)
	}

	if _, ok, err := v.Get("never-put", "default"); err != nil || ok {
		t.Fatalf("Get missing = ok %v err %v, want ok false err nil", ok, err)
	}
}

// TestPutOverwrites asserts a second Put for the same provider replaces the
// stored key (upsert semantics) rather than erroring or double-rowing.
func TestPutOverwrites(t *testing.T) {
	v, done := newTestVault(t)
	defer done()

	if err := v.Put("groq", "default", "first-key"); err != nil {
		t.Fatal(err)
	}
	if err := v.Put("groq", "default", "second-key"); err != nil {
		t.Fatalf("overwriting Put: %v", err)
	}
	got, ok, err := v.Get("groq", "default")
	if err != nil || !ok || got != "second-key" {
		t.Fatalf("Get after overwrite = (%q, %v, %v), want (second-key, true, nil)", got, ok, err)
	}
}

// TestPlaintextNeverAtRest asserts the ciphertext stored in the database is
// not the plaintext and does not contain it — AES-256-GCM output only.
func TestPlaintextNeverAtRest(t *testing.T) {
	v, done := newTestVault(t)
	defer done()

	secret := "sk-super-secret-key-material"
	if err := v.Put("zai", "default", secret); err != nil {
		t.Fatal(err)
	}
	var nonce, ciphertext []byte
	if err := v.db.QueryRow("SELECT nonce, ciphertext FROM provider_keys WHERE provider_id = 'zai'").Scan(&nonce, &ciphertext); err != nil {
		t.Fatalf("read stored row: %v", err)
	}
	if len(nonce) != 12 {
		t.Fatalf("stored nonce length = %d, want 12", len(nonce))
	}
	if len(ciphertext) <= len(secret) {
		t.Fatalf("ciphertext length %d too short for AES-256-GCM of %d-byte plaintext", len(ciphertext), len(secret))
	}
	if strings.Contains(string(ciphertext), secret) || strings.Contains(string(nonce), secret) {
		t.Fatal("plaintext (or a containing form of it) stored at rest")
	}
}

// TestTamperedCiphertextFails asserts corrupting the stored ciphertext makes
// Get fail with an error instead of returning corrupted plaintext.
func TestTamperedCiphertextFails(t *testing.T) {
	v, done := newTestVault(t)
	defer done()

	if err := v.Put("mistral", "default", "sk-live-mistral-key"); err != nil {
		t.Fatal(err)
	}
	if _, err := v.db.Exec("UPDATE provider_keys SET ciphertext = ? WHERE provider_id = 'mistral'", append([]byte("garbage-ciphertext"), 0x00)); err != nil {
		t.Fatalf("tamper setup: %v", err)
	}
	if _, _, err := v.Get("mistral", "default"); err == nil {
		t.Fatal("Get accepted tampered ciphertext")
	}
}

// TestMasterKeyMismatch asserts a vault opened with a different master key
// cannot read what another master key wrote.
func TestMasterKeyMismatch(t *testing.T) {
	d := t.TempDir()
	path := filepath.Join(d, "router.db")

	master1 := make([]byte, 32)
	master2 := make([]byte, 32)
	if _, err := rand.Read(master1); err != nil {
		t.Fatal(err)
	}
	if _, err := rand.Read(master2); err != nil {
		t.Fatal(err)
	}

	sqlDB1, err := db.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	v1, err := Open(sqlDB1, master1)
	if err != nil {
		sqlDB1.Close()
		t.Fatal(err)
	}
	if err := v1.Put("openrouter", "default", "sk-under-master1"); err != nil {
		t.Fatal(err)
	}
	sqlDB1.Close()

	sqlDB2, err := db.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer sqlDB2.Close()
	v2, err := Open(sqlDB2, master2)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := v2.Get("openrouter", "default"); err == nil {
		t.Fatal("vault with wrong master key decrypted a record it could not possibly open")
	}
}

// TestStatusDefaultUntested asserts a fresh Put leaves the key untested, that
// Status on an unknown provider errors, and that Status output never carries
// the plaintext.
func TestStatusDefaultUntested(t *testing.T) {
	v, done := newTestVault(t)
	defer done()

	secret := "sk-status-secret-plaintext"
	if err := v.Put("groq", "default", secret); err != nil {
		t.Fatal(err)
	}
	st, err := v.Status("groq", "default")
	if err != nil {
		t.Fatalf("Status: %v", err)
	}
	if st.State != Untested {
		t.Fatalf("fresh key state = %q, want %q", st.State, Untested)
	}
	if st.Detail == secret {
		t.Fatal("Status Detail leaked the plaintext key")
	}
	if _, err := v.Status("never-put", "default"); err == nil {
		t.Fatal("Status on unknown provider returned nil error")
	}
}

// TestSetStatusTransitions asserts the full untested → valid → invalid state
// machine round-trips through the database.
func TestSetStatusTransitions(t *testing.T) {
	v, done := newTestVault(t)
	defer done()

	if err := v.Put("cloudflare-workers-ai", "default", "sk-cf-token"); err != nil {
		t.Fatal(err)
	}

	now := time.Now().UTC().Truncate(time.Second)
	if err := v.SetStatus("cloudflare-workers-ai", "default", KeyStatus{State: Valid, LastChecked: now, Detail: "models endpoint 200"}); err != nil {
		t.Fatalf("SetStatus valid: %v", err)
	}
	st, err := v.Status("cloudflare-workers-ai", "default")
	if err != nil {
		t.Fatal(err)
	}
	if st.State != Valid {
		t.Fatalf("state = %q, want %q", st.State, Valid)
	}
	if !st.LastChecked.Equal(now) {
		t.Fatalf("LastChecked = %v, want %v", st.LastChecked, now)
	}
	if st.Detail != "models endpoint 200" {
		t.Fatalf("Detail = %q", st.Detail)
	}

	if err := v.SetStatus("cloudflare-workers-ai", "default", KeyStatus{State: Invalid, LastChecked: now, Detail: "401 unauthorised"}); err != nil {
		t.Fatalf("SetStatus invalid: %v", err)
	}
	st, err = v.Status("cloudflare-workers-ai", "default")
	if err != nil {
		t.Fatal(err)
	}
	if st.State != Invalid {
		t.Fatalf("state = %q, want %q", st.State, Invalid)
	}
}

// TestSetStatusRejectsUnknownState asserts the state vocabulary is closed and
// a rejected write does not stick.
func TestSetStatusRejectsUnknownState(t *testing.T) {
	v, done := newTestVault(t)
	defer done()

	if err := v.Put("ovhcloud-ai-endpoints", "default", "sk-ovh"); err != nil {
		t.Fatal(err)
	}
	if err := v.SetStatus("ovhcloud-ai-endpoints", "default", KeyStatus{State: KeyState("bogus")}); err == nil {
		t.Fatal("SetStatus accepted an unknown state")
	}
	st, err := v.Status("ovhcloud-ai-endpoints", "default")
	if err != nil {
		t.Fatal(err)
	}
	if st.State != Untested {
		t.Fatalf("state after rejected write = %q, want %q", st.State, Untested)
	}
}

// TestPutRejectsEmpty asserts empty keys are refused at the API boundary.
func TestPutRejectsEmpty(t *testing.T) {
	v, done := newTestVault(t)
	defer done()
	if err := v.Put("groq", "default", ""); err == nil {
		t.Fatal("Put accepted an empty key")
	}
	if err := v.Put("", "default", "some-key"); err == nil {
		t.Fatal("Put accepted an empty provider ID")
	}
}

// TestSetStatusRejectsEmptyProvider asserts SetStatus validates its provider
// ID even without a Put first.
func TestSetStatusRejectsEmptyProvider(t *testing.T) {
	v, done := newTestVault(t)
	defer done()
	if err := v.SetStatus("", "default", KeyStatus{State: Valid}); err == nil {
		t.Fatal("SetStatus accepted an empty provider ID")
	}
}

// TestOpenRejectsBadMasterKey asserts key-length validation.
func TestOpenRejectsBadMasterKey(t *testing.T) {
	sqlDB, err := db.Open(filepath.Join(t.TempDir(), "router.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer sqlDB.Close()
	if _, err := Open(sqlDB, []byte("too-short")); err == nil {
		t.Fatal("Open accepted a non-32-byte master key")
	}
}

// TestMasterKeyFromEnvOrFile covers the helper: env (hex) first, then a
// 0600-permission file generated on first use, then reuse of that file.
func TestMasterKeyFromEnvOrFile(t *testing.T) {
	d := t.TempDir()
	keyPath := filepath.Join(d, "master.key")

	master := make([]byte, 32)
	if _, err := rand.Read(master); err != nil {
		t.Fatal(err)
	}

	t.Setenv("MODEL_ROUTER_MASTER_KEY", hex.EncodeToString(master))
	got, err := MasterKeyFromEnvOrFile(keyPath)
	if err != nil {
		t.Fatal(err)
	}
	if hex.EncodeToString(got) != hex.EncodeToString(master) {
		t.Fatal("env-sourced master key does not round-trip")
	}

	// No env: file is generated with 0600 and reused byte-identically.
	t.Setenv("MODEL_ROUTER_MASTER_KEY", "")
	generated, err := MasterKeyFromEnvOrFile(keyPath)
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	if len(generated) != 32 {
		t.Fatalf("generated key length = %d, want 32", len(generated))
	}
	info, err := os.Stat(keyPath)
	if err != nil {
		t.Fatalf("key file missing: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("key file mode = %v, want 0600", info.Mode().Perm())
	}
	reread, err := MasterKeyFromEnvOrFile(keyPath)
	if err != nil {
		t.Fatal(err)
	}
	if hex.EncodeToString(reread) != hex.EncodeToString(generated) {
		t.Fatal("re-read master key differs from generated")
	}

	// Malformed env hex is an error, not a silently-ignored value.
	t.Setenv("MODEL_ROUTER_MASTER_KEY", "not-hex-at-all")
	if _, err := MasterKeyFromEnvOrFile(keyPath); err == nil {
		t.Fatal("malformed hex env accepted")
	}
}

// TestCryptoRoundTrip is the low-level crypto.go contract: seal then open with
// the same key returns the plaintext; a wrong key fails.
func TestCryptoRoundTrip(t *testing.T) {
	master := make([]byte, 32)
	if _, err := rand.Read(master); err != nil {
		t.Fatal(err)
	}
	nonce, ciphertext, err := seal(master, []byte("payload"))
	if err != nil {
		t.Fatal(err)
	}
	if len(nonce) != 12 {
		t.Fatalf("nonce length = %d, want 12", len(nonce))
	}
	plain, err := open(master, nonce, ciphertext)
	if err != nil {
		t.Fatal(err)
	}
	if string(plain) != "payload" {
		t.Fatalf("round-trip = %q", plain)
	}

	other := make([]byte, 32)
	if _, err := rand.Read(other); err != nil {
		t.Fatal(err)
	}
	if _, err := open(other, nonce, ciphertext); err == nil {
		t.Fatal("open succeeded with the wrong master key")
	}
}

// TestMasterKeyNeverRegeneratesOnReadError pins the final-review fix:
// only fs.ErrNotExist may mint a new key. A permission failure must
// surface an error and never regenerate (a fresh key would orphan every
// existing ciphertext permanently).
func TestMasterKeyNeverRegeneratesOnReadError(t *testing.T) {
	dir := t.TempDir()
	keyPath := filepath.Join(dir, "master.key")

	// seed an existing key so orphaning would be observable
	old, err := MasterKeyFromEnvOrFile(keyPath)
	if err != nil {
		t.Fatal(err)
	}
	// break readability WITHOUT removing the file: chmod 000
	if err := os.Chmod(keyPath, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(keyPath, 0o600) })

	got, err := MasterKeyFromEnvOrFile(keyPath)
	if err == nil {
		t.Fatal("permission failure must error, not regenerate")
	}
	// the minted key must NOT differ from the existing one
	if len(got) != 0 {
		t.Fatalf("no key should be returned on read failure, got %d bytes", len(got))
	}
	_ = old
}

// TestMultiKeyAliases asserts the multi-key contract: several aliases per
// provider, independent statuses, alias-scoped overwrite and delete, and
// active-alias filtering.
func TestMultiKeyAliases(t *testing.T) {
	v, done := newTestVault(t)
	defer done()

	if err := v.Put("groq", "main", "gsk-first"); err != nil {
		t.Fatal(err)
	}
	if err := v.Put("groq", "backup", "gsk-second"); err != nil {
		t.Fatal(err)
	}
	k1, ok1, err := v.Get("groq", "main")
	if err != nil || !ok1 || k1 != "gsk-first" {
		t.Fatalf("Get main = %q ok %v err %v", k1, ok1, err)
	}
	k2, ok2, err := v.Get("groq", "backup")
	if err != nil || !ok2 || k2 != "gsk-second" {
		t.Fatalf("Get backup = %q ok %v err %v", k2, ok2, err)
	}

	// statuses are independent per alias
	if err := v.SetStatus("groq", "main", KeyStatus{State: Valid}); err != nil {
		t.Fatal(err)
	}
	if err := v.SetStatus("groq", "backup", KeyStatus{State: Invalid, Detail: "401"}); err != nil {
		t.Fatal(err)
	}
	aliases, err := v.ActiveAliases("groq")
	if err != nil {
		t.Fatal(err)
	}
	if len(aliases) != 1 || aliases[0] != "main" {
		t.Fatalf("ActiveAliases = %v, want [main]", aliases)
	}

	// ListKeys returns both rows sorted by alias
	keys, err := v.ListKeys("groq")
	if err != nil {
		t.Fatal(err)
	}
	if len(keys) != 2 || keys[0].Alias != "backup" || keys[1].Alias != "main" {
		t.Fatalf("ListKeys = %+v", keys)
	}

	// alias-scoped overwrite: replacing main leaves backup alone
	if err := v.Put("groq", "main", "gsk-third"); err != nil {
		t.Fatal(err)
	}
	k2b, _, _ := v.Get("groq", "backup")
	if k2b != "gsk-second" {
		t.Fatalf("backup key changed after main overwrite: %q", k2b)
	}

	// delete one alias; the other survives
	if err := v.DeleteKey("groq", "main"); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := v.Get("groq", "main"); ok {
		t.Fatal("main still present after delete")
	}
	if k, ok, _ := v.Get("groq", "backup"); !ok || k != "gsk-second" {
		t.Fatalf("backup lost after main delete: %q ok %v", k, ok)
	}
}

// TestMultiKeyMigration asserts the 0003 migration carries v1 single-key
// rows across under the "default" alias and keeps them readable.
func TestMultiKeyMigration(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "router.db")

	// step 1: open fresh (runs all migrations incl. 0003)
	db1, err := db.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	master := make([]byte, 32)
	for i := range master {
		master[i] = byte(i)
	}
	v1, err := Open(db1, master)
	_ = v1
	if err != nil {
		db1.Close()
		t.Fatal(err)
	}

	// step 2: step the schema BACK to v1 (single-key) and insert a
	// legacy-style row sealed with the same master key; forget 0003 so
	// the next Open re-runs it against the v1-shaped table
	if _, err := db1.Exec(`DROP TABLE provider_keys`); err != nil {
		t.Fatal(err)
	}
	if _, err := db1.Exec(`DELETE FROM schema_migrations WHERE name = '0003_multikey.sql'`); err != nil {
		t.Fatal(err)
	}
	if _, err := db1.Exec(`CREATE TABLE provider_keys (provider_id TEXT PRIMARY KEY, nonce BLOB NOT NULL, ciphertext BLOB NOT NULL, status TEXT NOT NULL DEFAULT 'untested', last_checked_at TIMESTAMP, detail TEXT)`); err != nil {
		t.Fatal(err)
	}
	nonce, ciphertext, err := v1.sealForProvider("legacy", []byte("sk-legacy-key"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db1.Exec(`INSERT INTO provider_keys (provider_id, nonce, ciphertext) VALUES ('legacy', ?, ?)`, nonce, ciphertext); err != nil {
		t.Fatal(err)
	}
	if err := db1.Close(); err != nil {
		t.Fatal(err)
	}

	// step 3: reopen — the migrator sees the v1 table shape and runs 0003,
	// carrying the row across under "default"
	db2, err := db.Open(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer db2.Close()
	v2, err := Open(db2, master)
	if err != nil {
		t.Fatal(err)
	}
	k, ok, err := v2.Get("legacy", "default")
	if err != nil || !ok || k != "sk-legacy-key" {
		t.Fatalf("migrated key = %q ok %v err %v", k, ok, err)
	}
	aliases, err := v2.ActiveAliases("legacy")
	if err != nil || len(aliases) != 1 || aliases[0] != "default" {
		t.Fatalf("migrated aliases = %v err %v", aliases, err)
	}
}
