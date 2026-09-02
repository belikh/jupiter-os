-- Multi-key vault: one row per (provider, key alias). A provider may hold
-- several API keys — sibling keys absorb a 429 without demoting the whole
-- model (the corpus's hasOtherUsableKey finding), and pools spread load
-- across them like any other endpoint dimension. The API key is stored
-- only as AES-256-GCM ciphertext; status is the per-key lifecycle state.
-- detail must never hold plaintext key material.

CREATE TABLE IF NOT EXISTS provider_keys_v2 (
    provider_id     TEXT NOT NULL,
    key_alias       TEXT NOT NULL,
    nonce           BLOB NOT NULL,
    ciphertext      BLOB NOT NULL,
    status          TEXT NOT NULL DEFAULT 'untested' CHECK (status IN ('untested', 'valid', 'invalid', 'validating')),
    last_checked_at TIMESTAMP,
    detail          TEXT,
    PRIMARY KEY (provider_id, key_alias)
);

-- Carry the v1 rows across under the "default" alias.
INSERT OR IGNORE INTO provider_keys_v2 (provider_id, key_alias, nonce, ciphertext, status, last_checked_at, detail)
    SELECT provider_id, 'default', nonce, ciphertext, status, last_checked_at, detail FROM provider_keys;

DROP TABLE IF EXISTS provider_keys;
ALTER TABLE provider_keys_v2 RENAME TO provider_keys;
