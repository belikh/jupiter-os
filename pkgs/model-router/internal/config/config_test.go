package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// unsetTokenEnv removes ambient provider-token env vars so tests are
// hermetic against the host session (opencode fleet shells export
// MODEL_ROUTER_TOKEN for their own provider wiring; a test must not
// inherit it).
func unsetTokenEnv(t *testing.T) {
	t.Helper()
	if old, ok := os.LookupEnv("MODEL_ROUTER_TOKEN"); ok {
		os.Unsetenv("MODEL_ROUTER_TOKEN")
		t.Cleanup(func() { os.Setenv("MODEL_ROUTER_TOKEN", old) })
	}
}

// TestLoadDefaults asserts a first load with no existing config generates a
// client token and fills in the documented defaults.
func TestLoadDefaults(t *testing.T) {
	unsetTokenEnv(t)
	t.Chdir(t.TempDir()) // "./data" must land inside the sandbox
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.DataDir != "./data" {
		t.Fatalf("DataDir = %q, want ./data", cfg.DataDir)
	}
	if cfg.ListenAddr != ":8080" {
		t.Fatalf("ListenAddr = %q, want :8080", cfg.ListenAddr)
	}
	if len(cfg.ClientToken) != 64 { // 32 bytes hex-encoded
		t.Fatalf("ClientToken length = %d, want 64 hex chars", len(cfg.ClientToken))
	}
	if cfg.DBPath != filepath.Join("./data", "router.db") {
		t.Fatalf("DBPath = %q, want %q", cfg.DBPath, filepath.Join("./data", "router.db"))
	}
}

// TestSaveLoadRoundTrip asserts a config saved to disk loads back identically
// (token preserved, not regenerated).
func TestSaveLoadRoundTrip(t *testing.T) {
	t.Chdir(t.TempDir())
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if err := cfg.Save(); err != nil {
		t.Fatal(err)
	}

	reloaded, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if reloaded != cfg {
		t.Fatalf("round-trip mismatch: got %+v, want %+v", reloaded, cfg)
	}
}

// TestLoadGeneratesUniqueTokens asserts each fresh config gets a distinct
// crypto/rand token.
func TestLoadGeneratesUniqueTokens(t *testing.T) {
	unsetTokenEnv(t)
	t.Chdir(t.TempDir())
	a, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	t.Chdir(t.TempDir())
	b, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if a.ClientToken == b.ClientToken {
		t.Fatal("two fresh configs generated identical client tokens")
	}
}

// TestLoadAppliesDefaultListenAddr asserts a hand-edited config with an empty
// listen_addr loads with the default — an empty address would otherwise bind
// :80 while the log claims :8080.
func TestLoadAppliesDefaultListenAddr(t *testing.T) {
	d := t.TempDir()
	handEdited := `{"data_dir": "` + filepath.ToSlash(d) + `", "listen_addr": "", "client_token": "abc123", "db_path": "` + filepath.ToSlash(filepath.Join(d, "router.db")) + `"}`
	if err := os.WriteFile(filepath.Join(d, "config.json"), []byte(handEdited), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadDir(d)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.ListenAddr != defaultListenAddr {
		t.Fatalf("ListenAddr = %q, want default %q", cfg.ListenAddr, defaultListenAddr)
	}
}

// TestLoadPersistsRegeneratedToken asserts that when a config arrives with an
// empty client token, the regenerated token is written back to disk — clients
// must not see a new token on every restart.
func TestLoadPersistsRegeneratedToken(t *testing.T) {
	unsetTokenEnv(t)
	d := t.TempDir()
	handTrimmed := `{"data_dir": "` + filepath.ToSlash(d) + `", "listen_addr": ":9000", "client_token": "", "db_path": "` + filepath.ToSlash(filepath.Join(d, "router.db")) + `"}`
	if err := os.WriteFile(filepath.Join(d, "config.json"), []byte(handTrimmed), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadDir(d)
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.ClientToken) != 64 {
		t.Fatalf("ClientToken length = %d, want 64 hex chars", len(cfg.ClientToken))
	}

	// The saved file must now carry the regenerated token.
	raw, err := os.ReadFile(filepath.Join(d, "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), cfg.ClientToken) {
		t.Fatalf("config.json on disk does not contain the regenerated token: %s", raw)
	}

	// And a reload must return the same token, not a fresh one.
	reloaded, err := loadDir(d)
	if err != nil {
		t.Fatal(err)
	}
	if reloaded.ClientToken != cfg.ClientToken {
		t.Fatal("token changed across reload; regenerated token was not persisted")
	}
}

// TestSavedFileIsJSON asserts the persisted config is the expected JSON file
// in the data directory.
func TestSavedFileIsJSON(t *testing.T) {
	t.Chdir(t.TempDir())
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if err := cfg.Save(); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join("./data", "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"listen_addr"`) {
		t.Fatalf("config.json does not look like the expected JSON: %s", raw)
	}
}

func TestLoadDirEnvToken(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("MODEL_ROUTER_TOKEN", "fleet-shared-token-456")
	cfg, err := loadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.ClientToken != "fleet-shared-token-456" {
		t.Fatalf("first boot must take the env token: got %q", cfg.ClientToken)
	}
	// persisted: a second load (no env) keeps it
	t.Setenv("MODEL_ROUTER_TOKEN", "")
	cfg2, err := loadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if cfg2.ClientToken != "fleet-shared-token-456" {
		t.Fatalf("persisted token changed across boots: %q", cfg2.ClientToken)
	}
}
