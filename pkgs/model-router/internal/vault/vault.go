// Package vault stores provider API keys at rest as AES-256-GCM ciphertext.
// Each stored key gets a fresh random 12-byte nonce and is bound to its
// provider ID as GCM additional authenticated data, so ciphertext rows cannot
// be swapped between providers by editing the database. The master key never
// touches the database: it comes from the MODEL_ROUTER_MASTER_KEY environment
// variable (hex) or a 0600 key file generated on first use.
package vault

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"time"
)

// KeyState is the lifecycle state of a stored provider key.
type KeyState string

const (
	Untested KeyState = "untested" // stored, never validated
	Valid    KeyState = "valid"    // most recent probe succeeded
	Invalid  KeyState = "invalid"  // most recent probe failed (bad key, revoked, expired)
)

// KeyStatus is the outcome of the most recent validation probe for a key.
// It must never carry plaintext key material — Detail holds only probe
// diagnostics.
type KeyStatus struct {
	State       KeyState  `json:"state"`
	LastChecked time.Time `json:"last_checked"`
	Detail      string    `json:"detail"`
}

// Vault is the encrypted credential store over the router's SQLite database.
type Vault struct {
	db        *sql.DB
	masterKey []byte
}

// Open validates the master key and returns a Vault over the (already
// migrated) database. The master key must be exactly 32 bytes (AES-256).
func Open(db *sql.DB, masterKey []byte) (*Vault, error) {
	if db == nil {
		return nil, errors.New("vault: nil database")
	}
	if len(masterKey) != 32 {
		return nil, fmt.Errorf("vault: master key is %d bytes, want 32", len(masterKey))
	}
	if _, err := aes.NewCipher(masterKey); err != nil {
		return nil, fmt.Errorf("vault: master key unusable: %w", err)
	}
	return &Vault{db: db, masterKey: masterKey}, nil
}

// sealForProvider encrypts plaintext under the vault's master key, binding
// the ciphertext to providerID as additional authenticated data.
func (v *Vault) sealForProvider(providerID string, plaintext []byte) (nonce, ciphertext []byte, err error) {
	block, err := aes.NewCipher(v.masterKey)
	if err != nil {
		return nil, nil, fmt.Errorf("vault: aes cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, nil, fmt.Errorf("vault: gcm: %w", err)
	}
	nonce = make([]byte, nonceSize)
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, nil, fmt.Errorf("vault: read nonce entropy: %w", err)
	}
	ciphertext = gcm.Seal(nil, nonce, plaintext, []byte("modelrouter/provider_keys/"+providerID))
	return nonce, ciphertext, nil
}

// openForProvider decrypts a (nonce, ciphertext) pair that was sealed for
// providerID. Decryption fails if the row was sealed for a different
// provider, tampered with, or written under a different master key.
func (v *Vault) openForProvider(providerID string, nonce, ciphertext []byte) ([]byte, error) {
	block, err := aes.NewCipher(v.masterKey)
	if err != nil {
		return nil, fmt.Errorf("vault: aes cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("vault: gcm: %w", err)
	}
	if len(nonce) != nonceSize {
		return nil, fmt.Errorf("vault: nonce is %d bytes, want %d", len(nonce), nonceSize)
	}
	plaintext, err := gcm.Open(nil, nonce, ciphertext, []byte("modelrouter/provider_keys/"+providerID))
	if err != nil {
		return nil, fmt.Errorf("vault: decrypt key for %s: %w", providerID, err)
	}
	return plaintext, nil
}

// Put stores an API key for a provider, replacing any previous key. The key
// is sealed with a fresh nonce and stored as ciphertext only. A newly stored
// key's status resets to untested.
func (v *Vault) Put(providerID, key string) error {
	if providerID == "" {
		return errors.New("vault: empty provider ID")
	}
	if key == "" {
		return errors.New("vault: empty key")
	}
	nonce, ciphertext, err := v.sealForProvider(providerID, []byte(key))
	if err != nil {
		return err
	}
	_, err = v.db.Exec(`INSERT INTO provider_keys (provider_id, nonce, ciphertext, status, last_checked_at, detail)
		VALUES (?, ?, ?, 'untested', NULL, NULL)
		ON CONFLICT(provider_id) DO UPDATE SET
			nonce = excluded.nonce,
			ciphertext = excluded.ciphertext,
			status = 'untested',
			last_checked_at = NULL,
			detail = NULL`,
		providerID, nonce, ciphertext)
	if err != nil {
		return fmt.Errorf("vault: store key for %s: %w", providerID, err)
	}
	return nil
}

// Get retrieves a provider's plaintext key. ok is false when no key is stored
// for the provider.
func (v *Vault) Get(providerID string) (key string, ok bool, err error) {
	var nonce, ciphertext []byte
	err = v.db.QueryRow(`SELECT nonce, ciphertext FROM provider_keys WHERE provider_id = ?`, providerID).
		Scan(&nonce, &ciphertext)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, fmt.Errorf("vault: fetch key for %s: %w", providerID, err)
	}
	plaintext, err := v.openForProvider(providerID, nonce, ciphertext)
	if err != nil {
		return "", false, err
	}
	return string(plaintext), true, nil
}

// Status returns the most recent validation status for a provider's key. It
// errors when no key is stored. The returned KeyStatus never contains
// plaintext key material.
func (v *Vault) Status(providerID string) (KeyStatus, error) {
	var state string
	var lastChecked sql.NullTime
	var detail sql.NullString
	err := v.db.QueryRow(`SELECT status, last_checked_at, detail FROM provider_keys WHERE provider_id = ?`, providerID).
		Scan(&state, &lastChecked, &detail)
	if errors.Is(err, sql.ErrNoRows) {
		return KeyStatus{}, fmt.Errorf("vault: no key stored for %s", providerID)
	}
	if err != nil {
		return KeyStatus{}, fmt.Errorf("vault: fetch status for %s: %w", providerID, err)
	}
	st := KeyStatus{State: KeyState(state), Detail: detail.String}
	if lastChecked.Valid {
		st.LastChecked = lastChecked.Time
	}
	switch st.State {
	case Untested, Valid, Invalid:
	default:
		return KeyStatus{}, fmt.Errorf("vault: stored state %q for %s is not a known state", state, providerID)
	}
	return st, nil
}

// SetStatus records a validation outcome for a provider's stored key. It
// refuses unknown states at the API boundary so the closed vocabulary in the
// database CHECK constraint stays closed.
func (v *Vault) SetStatus(providerID string, status KeyStatus) error {
	if providerID == "" {
		return errors.New("vault: empty provider ID")
	}
	switch status.State {
	case Untested, Valid, Invalid:
	default:
		return fmt.Errorf("vault: unknown key state %q", status.State)
	}
	var detail any
	if status.Detail != "" {
		detail = status.Detail
	}
	var lastChecked any
	if !status.LastChecked.IsZero() {
		lastChecked = status.LastChecked.UTC()
	}
	res, err := v.db.Exec(`UPDATE provider_keys SET status = ?, last_checked_at = ?, detail = ? WHERE provider_id = ?`,
		string(status.State), lastChecked, detail, providerID)
	if err != nil {
		return fmt.Errorf("vault: set status for %s: %w", providerID, err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("vault: no key stored for %s", providerID)
	}
	return nil
}

// MasterKeyFromEnvOrFile resolves the vault master key: the
// MODEL_ROUTER_MASTER_KEY environment variable (64 hex chars) wins; otherwise
// the key is read from (or generated into) keyPath with 0600 permissions.
// The generated form is 32 bytes of crypto/rand entropy written once and
// reused on every later run.
func MasterKeyFromEnvOrFile(keyPath string) ([]byte, error) {
	if hexKey := os.Getenv("MODEL_ROUTER_MASTER_KEY"); hexKey != "" {
		key, err := hex.DecodeString(hexKey)
		if err != nil {
			return nil, fmt.Errorf("vault: MODEL_ROUTER_MASTER_KEY is not valid hex: %w", err)
		}
		if len(key) != 32 {
			return nil, fmt.Errorf("vault: MODEL_ROUTER_MASTER_KEY decodes to %d bytes, want 32", len(key))
		}
		return key, nil
	}

	if keyPath == "" {
		return nil, errors.New("vault: no master key env var and no key file path")
	}
	// a directory (the data dir) means the conventional master.key inside it
	if fi, err := os.Stat(keyPath); err == nil && fi.IsDir() {
		keyPath = filepath.Join(keyPath, "master.key")
	}
	key, readErr := os.ReadFile(keyPath)
	if readErr == nil {
		if len(key) != 32 {
			return nil, fmt.Errorf("vault: key file %s holds %d bytes, want 32", keyPath, len(key))
		}
		return key, nil
	}
	// regenerate ONLY on not-exists: any other read failure (permissions,
	// transient I/O) must not mint a fresh key — a new key would orphan
	// every existing ciphertext permanently.
	if !errors.Is(readErr, fs.ErrNotExist) {
		return nil, fmt.Errorf("vault: read master key file %s: %w", keyPath, readErr)
	}

	key = make([]byte, 32)
	if _, err := io.ReadFull(rand.Reader, key); err != nil {
		return nil, fmt.Errorf("vault: read master key entropy: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(keyPath), 0o700); err != nil {
		return nil, fmt.Errorf("vault: create key directory: %w", err)
	}
	if err := os.WriteFile(keyPath, key, 0o600); err != nil {
		return nil, fmt.Errorf("vault: write master key file %s: %w", keyPath, err)
	}
	return key, nil
}
