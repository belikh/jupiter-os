#!/usr/bin/env bash
# Seed deterministic test state for a Niro run, through the application's own
# API only.
#
# Steps:
#   1. materialise the committed fixture ROM corpus (fixturegen is
#      deterministic: bytes keyed by system+filename, matching the committed
#      DATs in pkgs/arcade-webapp/testdata/dats)
#   2. stage the DATs where the scanner reads them
#   3. POST /rescan and wait until /inventory.json reports the corpus
#   4. create (or reuse) the "Niro Fixture Collection" through the HTTP API and
#      add one game per system
#   5. write the gitignored niro/credentials.yaml + niro/fixtures.yaml
#
# Idempotent: re-running regenerates byte-identical fixtures, the rescan
# absorbs them, and collection create/add reconcile to the same state.
set -euo pipefail
# shellcheck source=niro/harness/env.sh
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
cd "$REPO_ROOT"

app_running || fail "arcade-webapp is not running; run niro/harness/start.sh first"
wait_for_health 10 || fail "$BASE_URL/healthz is not answering"

# The app's mutation gate (internal/web hardening.go): every POST requires this
# header, otherwise it is refused 403. Niro learns the same fact from the
# static_token in the generated credentials.yaml.
HX_HEADER="HX-Request: true"
COLLECTION_NAME="Niro Fixture Collection"
COLLECTION_SUMMARY="Deterministic collection created by niro/harness/seed.sh"

# ---- 1. fixture ROM corpus (deterministic, self-authored) ------------------
log "generating fixture ROM corpus under $GAMES_ROOT/cartridge"
rm -rf "$GAMES_ROOT/cartridge"
mkdir -p "$GAMES_ROOT/cartridge"
"${GO_CMD[@]}" -C "$APP_DIR" run ./cmd/fixturegen --roms "$GAMES_ROOT/cartridge"

# ---- 2. DATs ---------------------------------------------------------------
mkdir -p "$DATS_DIR"
cp -f "$APP_DIR"/testdata/dats/*.dat "$DATS_DIR/"

# ---- 3. rescan + wait ------------------------------------------------------
log "triggering POST /rescan"
rescan_code="$(curl -sS -o /dev/null -w '%{http_code}' -H "$HX_HEADER" -X POST "$BASE_URL/rescan" || true)"
case "$rescan_code" in
  202 | 409) ;; # 202 accepted; 409 = a scan was already running
  *) fail "POST /rescan answered $rescan_code (want 202 or 409)" ;;
esac

# encoding/json sorts map keys, so each system appears as "nes":{"count":5,...
# — a deterministic substring to poll for.
log "waiting for the scan to report the fixture corpus"
scan_ok=0
for _ in $(seq 1 60); do
  inventory="$(curl -fsS --max-time 5 "$BASE_URL/inventory.json" 2>/dev/null || true)"
  if grep -q '"nes":{"count":5' <<<"$inventory" \
    && grep -q '"snes":{"count":4' <<<"$inventory" \
    && grep -q '"gb":{"count":4' <<<"$inventory"; then
    scan_ok=1
    break
  fi
  sleep 1
done
[ "$scan_ok" = 1 ] || fail "fixture corpus never appeared in /inventory.json (expected nes=5, snes=4, gb=4)"
log "scan reports nes=5, snes=4, gb=4"

# ---- 4. collection through the API -----------------------------------------
# GET /collections list rows as <tr data-collection="<id>"> followed by
# <td><a href="/collections/<id>">Name</a>. Reuse the collection when it
# already exists so re-running seed never creates duplicates.
cid="$(curl -fsS "$BASE_URL/collections" | awk -v want="$COLLECTION_NAME" '
  /data-collection="/ {
    match($0, /data-collection="[0-9]+"/)
    id = substr($0, RSTART + 17, RLENGTH - 18)
    next
  }
  id != "" {
    if (index($0, ">" want "<") > 0) { print id; exit }
    id = ""
  }
')"

if [ -z "$cid" ]; then
  response="$(curl -fsS -H "$HX_HEADER" \
    --data-urlencode "name=$COLLECTION_NAME" \
    --data-urlencode "summary=$COLLECTION_SUMMARY" \
    -X POST "$BASE_URL/collections/create")" || fail "POST /collections/create failed"
  cid="$(sed -n 's|.*href="/collections/\([0-9]*\)".*|\1|p' <<<"$response" | head -1)"
  [ -n "$cid" ] || fail "created collection id not found in the API response"
  log "created collection $cid ($COLLECTION_NAME)"
else
  log "reusing collection $cid ($COLLECTION_NAME)"
fi

# One deterministic member per fixture system. The store makes add idempotent,
# so repeated seeds converge on the same membership.
for pair in "nes:Starlit Vault" "snes:Astral Almari" "gb:Pocket Plumber"; do
  system="${pair%%:*}"
  title="${pair#*:}"
  page="$(curl -fsS --get --data-urlencode "q=$title" --data-urlencode "system=$system" \
    "$BASE_URL/library")" || fail "GET /library?q=$title&system=$system failed"
  href="$(awk '/class="gcard" href="/ { match($0, /href="[^"]*"/); h = substr($0, RSTART + 6, RLENGTH - 7) } /gcard-title" title="'"$title"'/ { print h; exit }' <<<"$page")"
  [ -n "$href" ] || fail "no library card found for '$title' in $system"
  game_id="$(sed -n 's|.*/games/\([0-9]*\).*|\1|p' <<<"$href")"
  [ -n "$game_id" ] || fail "could not parse the game id from '$href'"
  code="$(curl -sS -o /dev/null -w '%{http_code}' -H "$HX_HEADER" \
    -X POST "$BASE_URL/collections/$cid/add?system=$system&game=$game_id")"
  [ "$code" = 200 ] || fail "POST /collections/$cid/add ($system/$game_id) answered $code"
  log "collection member $system/$game_id ($title)"
done

# ---- 5. generated credentials + fixtures (gitignored) ----------------------
# The app is intentionally unauthenticated: no login, no sessions, no cookies.
# Its only access gate is the htmx header above, modelled as a static_token so
# the attacker agent knows exactly where the value is sent.
cat >"$REPO_ROOT/niro/credentials.yaml" <<YAML
# Generated by niro/harness/seed.sh — do not commit (gitignored).
credentials:
  - credential_id: HTMX_MUTATION_HEADER
    description: "Not an identity credential: this app has no authentication (no login, sessions or cookies). Every mutating endpoint (all POSTs) requires the header HX-Request with value true — the legacy X-HX-Request header is also accepted — and a request without it is refused 403 by the app's hxRequestOK gate. Send as header:HX-Request."
    type: static_token
    secret: "true"
YAML

cat >"$REPO_ROOT/niro/fixtures.yaml" <<YAML
# Generated by niro/harness/seed.sh — do not commit (gitignored).
fixtures:
  - name: app_url
    description: "The local arcade-webapp runtime started by niro/harness/start.sh. Loopback only: niro/scope.yaml authorises exactly this host and port and nothing else."
    value: "http://127.0.0.1:18094"

  - name: app_bind
    description: "The harness binds 0.0.0.0:18094 so Niro's attack container can reach the host listener; the committed scope still authorises only 127.0.0.1 and localhost, never a LAN IP or tailnet name."
    value: "0.0.0.0:18094"

  - name: fixture_corpus
    description: "Deterministic self-authored ROM corpus generated by pkgs/arcade-webapp/cmd/fixturegen and verified against the committed DATs. After seed the scanner reports exactly these counts, and the games below are the members of the seeded collection."
    value:
      systems:
        nes: 5
        snes: 4
        gb: 4
      games:
        nes: "Starlit Vault (USA).nes"
        snes: "Astral Almari (USA).sfc"
        gb: "Pocket Plumber (USA).gb"
      roots:
        cartridge: "niro/harness/run/games/cartridge"
        dats: "niro/harness/run/dats"

  - name: seeded_collection
    description: "Collection created through POST /collections/create (idempotent) with one member per fixture system, added via POST /collections/<id>/add."
    value:
      id: $cid
      name: "$COLLECTION_NAME"

  - name: fleet_config_surface
    description: "The jupiterOS fleet configuration this run is asked to review: per-host NixOS configuration, the reusable modules (network exposure, sops secret handling, systemd services) and the authority documents. Static review only — no production host is reachable from this profile (loopback-only scope)."
    value:
      hosts: "hosts/"
      modules: "modules/"
      flake: "flake.nix"
      stack_guide: "docs/stack-guide.md"
      style_guide: "docs/style-guide.md"
YAML

log "wrote niro/credentials.yaml and niro/fixtures.yaml"
log "seed complete"
