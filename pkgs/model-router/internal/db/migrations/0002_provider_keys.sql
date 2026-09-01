-- Encrypted credential vault: one row per provider. The API key is stored
-- only as AES-256-GCM ciphertext (nonce + ciphertext columns); the master key
-- lives outside the database (env var or key file). status is the
-- untested|valid|invalid lifecycle state; last_checked_at and detail record
-- the most recent key-validation probe. detail must never hold plaintext key
-- material.

CREATE TABLE IF NOT EXISTS provider_keys (
    provider_id     TEXT PRIMARY KEY,
    nonce           BLOB NOT NULL,
    ciphertext      BLOB NOT NULL,
    status          TEXT NOT NULL DEFAULT 'untested' CHECK (status IN ('untested', 'valid', 'invalid')),
    last_checked_at TIMESTAMP,
    detail          TEXT
);
