-- Baseline schema for the model router. Migrations are applied in lexical
-- filename order and recorded in schema_migrations.

CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT
);
