# Incident note: 2026-09-30 jupiter.au Access JWT in agent transcript

**Severity:** medium (transient ~24h Cloudflare Access JWT; no fleet secrets,
no Cloudflare API token, no EmDash session token).
**Status at writing:** log copy scrubbed; stateless token left to expire
(no per-token revocation exists — see "Required follow-ups").

## What happened

While establishing live access to the jupiter.au EmDash admin from callisto
(installing the `emdash-site` OpenDesign plugin against the live site rather
than a local scaffold), `cloudflared access login https://jupiter.au/_emdash/admin`
was run in the background with stdout captured to
`/tmp/opencode/cf-access-login.log`.

After the browser login completed, the verification step ran `tail -5` on that
log. `cloudflared` prints the fetched JWT to stdout on success
("Successfully fetched your token:" followed by the signed JWT), so the full
Access JWT entered the AI session transcript as a tool result.

The house rule (binding since the 2026-09-06 incident): secrets never enter
transcripts. Any plaintext secret that enters context is treated as burned.

## Blast radius

- One credential: a Cloudflare Access JWT for the `jupiter.au` Access
  application (aud `b13f12e4…1441d`, `/_emdash/*`), identity
  `io@djr.net.au`, issuer `belic.cloudflareaccess.com`.
- Validity: issued ~2026-09-30 13:52 AEST, `exp` 24h later. The EmDash
  deployment uses `auth: access()` as its exclusive production auth, so within
  the window this JWT authenticates requests to the site's protected
  `/_emdash/*` routes (admin and REST API) as that identity.
- NOT exposed: `secrets/secrets.yaml` values, Cloudflare API tokens (none
  exist), the EmDash CLI token (not yet minted at the time), D1/R2 credentials,
  SSH/TLS material.
- The same JWT is cached as intended (0600) at
  `~/.cloudflared/jupiter.au-<aud>-token` on callisto for CLI use; that cache is
  not the exposure. The exposure is the transcript copy.

## Actions taken

- Deleted `/tmp/opencode/cf-access-login.log` (and the login-URL scratch file)
  immediately; the token value was never printed again.
- Did not re-run `cloudflared access token` or any command that echoes the JWT;
  subsequent checks use the cache file or the CLI's own auth path.
- **Retired the credential from use the same day (2026-09-30):** the CLI was
  switched to a dedicated Cloudflare Access *service token* (policy
  `open-design service token`, decision `non_identity`) plus the EmDash API
  token, and the `~/.cloudflared/jupiter.au-*` JWT cache was deleted. No
  running process depends on the leaked JWT; it remains signature-valid until
  its 24h expiry, after which it is inert.

## Required follow-ups

- [x] ~~**Optional, only if the exposure window is judged unacceptable:** rotate
  the Access application's audience ...~~ **Superseded 2026-09-30:** the JWT is
  no longer used by any process and its cache was removed, so audience rotation
  would add an admin outage without reducing a live risk. It expires 24h after
  issue.
- [x] For unattended automation, prefer a dedicated Access **service token**
  over the browser JWT flow, with an explicit service-token policy on the
  app and the secret handled via sops extract-and-pipe (never in a transcript).
  **Done 2026-09-30** — token `open-design`, policy `non_identity`; secret
  moved via an RSA-OAEP envelope (ciphertext only in the session).
- [ ] Never capture `cloudflared` stdout to a file that is later read; use
  `cloudflared access token >/dev/null`-style checks or inspect only the cache
  file's metadata.
