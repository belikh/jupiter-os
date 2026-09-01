// Package vault stores provider API keys at rest as AES-256-GCM ciphertext.
// Each stored key gets a fresh random 12-byte nonce and is bound to its
// provider ID as GCM additional authenticated data, so ciphertext rows cannot
// be swapped between providers by editing the database. The master key never
// touches the database: it comes from the MODEL_ROUTER_MASTER_KEY environment
// variable (hex) or a 0600 key file generated on first use.
//
// crypto.go holds the raw AES-256-GCM primitives; the provider-bound variants
// the Vault type uses live in vault.go.
package vault

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"fmt"
	"io"
)

// nonceSize is the standard GCM nonce length.
const nonceSize = 12

// newGCM constructs the AES-256-GCM instance for a 32-byte master key.
func newGCM(masterKey []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(masterKey)
	if err != nil {
		return nil, fmt.Errorf("aes cipher: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("gcm: %w", err)
	}
	return gcm, nil
}

// seal encrypts plaintext under masterKey with a fresh random 12-byte nonce
// and no additional data. It returns (nonce, ciphertext); the GCM
// authentication tag is inside ciphertext.
func seal(masterKey, plaintext []byte) (nonce, ciphertext []byte, err error) {
	gcm, err := newGCM(masterKey)
	if err != nil {
		return nil, nil, err
	}
	nonce = make([]byte, nonceSize)
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, nil, fmt.Errorf("read nonce entropy: %w", err)
	}
	ciphertext = gcm.Seal(nil, nonce, plaintext, nil)
	return nonce, ciphertext, nil
}

// open decrypts a (nonce, ciphertext) pair under masterKey. It fails if the
// pair was written under a different key or tampered with after sealing.
func open(masterKey, nonce, ciphertext []byte) ([]byte, error) {
	gcm, err := newGCM(masterKey)
	if err != nil {
		return nil, err
	}
	if len(nonce) != nonceSize {
		return nil, fmt.Errorf("nonce is %d bytes, want %d", len(nonce), nonceSize)
	}
	plaintext, err := gcm.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return nil, fmt.Errorf("decrypt: %w", err)
	}
	return plaintext, nil
}
