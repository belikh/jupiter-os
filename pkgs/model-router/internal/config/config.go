// Package config loads and persists the router's application config to
// config.json in the data directory.
package config

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

// Config is the application configuration. It is JSON-serialised to
// config.json in the data directory.
type Config struct {
	DataDir     string `json:"data_dir"`
	ListenAddr  string `json:"listen_addr"`
	ClientToken string `json:"client_token"`
	DBPath      string `json:"db_path"`
}

// filename is the config file name inside the data directory.
const filename = "config.json"

// defaultDataDir is where the router keeps its database and config when the
// operator has not specified otherwise.
// MODEL_ROUTER_DATA_DIR overrides the default data directory (the NixOS
// module sets it so state lands in /var/lib/model-router).
const defaultDataDir = "./data"

func envDefaultDataDir() string {
	if v := os.Getenv("MODEL_ROUTER_DATA_DIR"); v != "" {
		return v
	}
	return defaultDataDir
}

// defaultListenAddr is the address the HTTP facade listens on.
const defaultListenAddr = ":8080"

// tokenBytes is the entropy in the generated client token.
const tokenBytes = 32

// Load reads config.json from the default data directory (./data), or — when
// no file exists yet — creates the directory, generates a client token, and
// saves a fresh config. The returned Config's DBPath always points at
// router.db inside the data directory.
func Load() (Config, error) {
	return loadDir(envDefaultDataDir())
}

// loadDir is Load with an explicit data directory, used by tests.
func loadDir(dir string) (Config, error) {
	var cfg Config

	raw, err := os.ReadFile(filepath.Join(dir, filename))
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return fresh(dir)
	case err != nil:
		return cfg, fmt.Errorf("read config: %w", err)
	}

	if err := json.Unmarshal(raw, &cfg); err != nil {
		return cfg, fmt.Errorf("parse config: %w", err)
	}
	if cfg.DataDir == "" {
		cfg.DataDir = dir
	}
	// MODEL_ROUTER_TOKEN pre-seeds the client bearer token (the NixOS module
	// sets it from a sops secret so consumers — opencode, OpenDesign, dsh —
	// share one credential without reading the router's data dir).
	if v := os.Getenv("MODEL_ROUTER_TOKEN"); v != "" && cfg.ClientToken == "" {
		cfg.ClientToken = v
	}
	// MODEL_ROUTER_LISTEN_ADDR overrides the listen address (the NixOS module
	// sets it from its port option so loopback binding is explicit).
	if v := os.Getenv("MODEL_ROUTER_LISTEN_ADDR"); v != "" && cfg.ListenAddr == "" {
		cfg.ListenAddr = v
	}
	if cfg.ListenAddr == "" {
		// A hand-edited or partially serialised config must not fall back to
		// the :80 default — net/http's ListenAndServe with an empty Addr
		// silently binds :80 while the log claims :8080.
		cfg.ListenAddr = defaultListenAddr
	}
	if cfg.DBPath == "" {
		cfg.DBPath = filepath.Join(cfg.DataDir, "router.db")
	}
	if cfg.ClientToken == "" {
		// Corrupt or hand-trimmed file: regenerate rather than run with an
		// unauthenticated facade, and persist immediately so clients do not
		// see a different token on every restart.
		token, err := newToken()
		if err != nil {
			return cfg, err
		}
		cfg.ClientToken = token
		if err := cfg.Save(); err != nil {
			return cfg, err
		}
	}
	return cfg, nil
}

// fresh builds and persists a first-run config in dir. The listen address
// honours MODEL_ROUTER_LISTEN_ADDR from the very first boot — a fresh data
// dir must not silently fall back to :8080 when the NixOS module pins
// loopback binding.
func fresh(dir string) (Config, error) {
	token := os.Getenv("MODEL_ROUTER_TOKEN")
	if token == "" {
		var err error
		token, err = newToken()
		if err != nil {
			return Config{}, err
		}
	}
	listenAddr := defaultListenAddr
	if v := os.Getenv("MODEL_ROUTER_LISTEN_ADDR"); v != "" {
		listenAddr = v
	}
	cfg := Config{
		DataDir:     dir,
		ListenAddr:  listenAddr,
		ClientToken: token,
		DBPath:      filepath.Join(dir, "router.db"),
	}
	if err := cfg.Save(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// Save writes the config to config.json in the data directory, creating the
// directory if needed. Save is safe to call repeatedly (round-trip stable).
func (c Config) Save() error {
	if err := os.MkdirAll(c.DataDir, 0o755); err != nil {
		return fmt.Errorf("create data dir: %w", err)
	}
	raw, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return fmt.Errorf("encode config: %w", err)
	}
	if err := os.WriteFile(filepath.Join(c.DataDir, filename), raw, 0o600); err != nil {
		return fmt.Errorf("write config: %w", err)
	}
	return nil
}

// newToken returns a fresh 32-byte hex token from crypto/rand.
func newToken() (string, error) {
	buf := make([]byte, tokenBytes)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("generate client token: %w", err)
	}
	return hex.EncodeToString(buf), nil
}
