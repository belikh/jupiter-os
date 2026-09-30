# Incident note: 2026-09-30 HA long-lived token in agent transcript

**Severity:** medium (single HA LLAT; no fleet or provider secrets).
**Status at writing:** rotation **done** same minute (new token minted over
WS, env file rewritten 0600, verified `GET /api/` 200). Old token revocation
is an owner action (see below).

## What happened

While wiring the roster-writer MQTT repair during the Jupiter Quarters
migration, an agent shell pipeline `eval`'d the first line of
`~/.config/ha-strategy/llat-new.env`. That file holds a **bare JWT** (no
`VAR=` prefix), so the eval executed the token as a command and bash's
"command not found" error echoed it into the agent transcript.

## Exposure surface

The agent transcript only. No repo files, application logs, broker records
or database rows carried the value.

## Immediate actions

1. Replacement LLAT minted over the HA WebSocket API
   (`auth/long_lived_access_token`, client name `zeus-rotated-20260930b`,
   10-year lifespan) and written atomically to the env file (mode 0600);
   verified with `GET /api/` → 200. Only lengths were printed.
2. No scrub needed — the file lives outside every repository and no copies
   exist in tracked files.
3. Migration evidence note: `ha-strategy`
   `ha-config-export/evidence/INCIDENT-2026-09-30-llat-transcript.md`.

## Required follow-up (owner)

- **Revoke the burned token** in the HA UI (profile → Security → long-lived
  access tokens → delete the pre-rotation `zeus` entry).

## Lessons

- Never `eval` / `cat` secret-bearing files into a shell line that can echo.
  Read them via `$(cat path)` strictly inside argument position, or better,
  have the consuming process read the file itself (systemd wrapper pattern).
- `~/.config/ha-strategy/llat-new.env` contains a bare token, not an
  assignment.
