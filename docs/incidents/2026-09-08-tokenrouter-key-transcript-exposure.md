# Incident note: 2026-09-08 TokenRouter key exposure in verification transcript

**Severity:** medium (single shared provider credential, no fleet secrets).
**Status at writing:** rotation **not yet done** — owner action required (see
"Required follow-ups").

## What happened

While verifying the freshly deployed tokenrouter provider in the matt
opencode environment (`modules/core/opencode.nix`, commit `07cebf9`),
a verification one-liner ran:

```
opencode-matt debug config | python3 -c "... print('tokenrouter key ref:', tr.get('options',{}).get('apiKey'))"
```

That was intended to confirm the config carried the `{env:TOKENROUTER_API_KEY}`
*reference*. But `debug config` prints the **resolved** config — under the
wrapper, opencode had already interpolated the `{env:}` placeholder with the
live environment value, so the printed field was the **actual TokenRouter API
key** (an `sk-…` literal), not the reference. The value entered the AI session
transcript (the tool result).

The house rule (binding since the 2026-09-06 incident): secrets never enter
transcripts. Any plaintext secret that enters context is treated as burned.

## Blast radius

- One credential: `tokenrouter_api_key` in `secrets/secrets.yaml` — the
  TokenRouter (api.tokenrouter.com) aggregator key.
- Consumers: io's `opencode` wrapper and matt's `opencode-matt` wrapper
  (`modules/core/opencode.nix`), both via
  `sops.secrets.tokenrouter_api_key(_matt)`. No other module references it.
- NOT exposed: z.ai key, groq key, `dsh_env` contents, MQTT/DB passwords,
  model-router vault, any TLS/SSH material. Verified post-incident that no
  repo file carries the literal (`git grep 'sk-…'` clean; the only pattern
  match is a test fixture regex in `pkgs/model-router/internal/vault/
  vault_test.go`, not a real key).
- Context is not a secure boundary: treat the value as potentially logged
  by every hop in the AI pipeline and usable for later-model training.

## Root cause

Verification code asked for the wrong thing. The correct assertion was
"apiKey starts with `{env:`", i.e. prove the *reference* shape; instead it
printed the field, and under the wrapper the field had already been resolved.
Two compounding factors:

1. `opencode debug config` output is the **resolved** config (interpolated),
   not the raw JSON on disk — easy to forget when the wrapper exports the
   secret.
2. Prior verifications in the same session printed `providers`/`models` only,
   which is why earlier sweeps were safe; this one added a new field without
   re-checking what that field contains under the wrapper.

## Rules this violates (pre-existing, binding)

- Global agent instructions: "Secrets never enter transcripts … Reading a
  secret into a shell variable is fine; `echo`/`cat`/`jq` of that variable
  into transcript is the violation. Use `wc -c`, hash prefixes, or boolean
  checks as receipts instead."
- jupiter-os CLAUDE.md: "NEVER echo a token/password/key value into chat."

## Required follow-ups (owner)

1. **Rotate the TokenRouter key** at api.tokenrouter.com, then update
   `tokenrouter_api_key` in `secrets/secrets.yaml` (sops set) and deploy
   (both wrappers read the same sops key, so one rotation covers io + matt).
2. Optionally raise a TokenRouter support ticket to revoke the old key's
   sessions if the dashboard shows recent activity from an unexpected IP.
3. This note is the required incident record; no repo copy of the value
   exists to scrub (the transcript copy is outside repo control).

## Prevention

- Never print resolved config under a credential-exporting wrapper. Assert
  reference shapes instead, e.g.:
  `jq -e '.provider.tokenrouter.options.apiKey == "{env:TOKENROUTER_API_KEY}"'`
  against the **on-disk** JSON (which is the raw reference), or grep the
  store-path JSON for the `{env:` prefix.
- Receipts for secret presence: file-exists + owner + mode (`stat`), grep
  count of the env-var *name* in the wrapper text, never the value.
