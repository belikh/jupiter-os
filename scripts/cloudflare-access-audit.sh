#!/usr/bin/env bash
# cloudflare-access-audit.sh — inventory Cloudflare tunnels/DNS/Access and
# classify tunneled hostnames as secured | public | exposed | dangling.
#
# Requires: curl, jq
# Env:
#   CLOUDFLARE_API_TOKEN   (required)
#   CLOUDFLARE_ACCOUNT_ID  (default: Jupiter Systems)
#
# Exit codes:
#   0  all must-secure hostnames are secured (anonymous blocked)
#   1  one or more must-secure hostnames are exposed, or API/probe failure
#   2  usage / missing token
#
# Zero secrets in repo. Token only via environment.
set -euo pipefail

ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-19f62c2ef7861336d274166233ba3a17}"
API_BASE="https://api.cloudflare.com/client/v4"
# Reusable Access policy "me" (email_domain: djr.net.au)
POLICY_ME_ID="b9c394a3-62e9-42e5-8695-7cc2ddfe7ebe"

# --- classification config (user decisions 2026-08-18) ---
# Hostnames intentionally left public (no Access app required).
KNOWN_PUBLIC=(
  cache.jupiter.au
  headscale.jupiter.au
  rpc.jupiter.au
)

# Hostnames that MUST have Access + policy me; anonymous must be blocked.
MUST_SECURE=(
  dsh.jupiter.au
  aeon.jupiter.au
  nom.jupiter.au
  ariang.jupiter.au
  n8n.jupiter.au
)

# Hostnames deliberately left WITHOUT Access (user decision 2026-08-18).
# Enumerated but never gated; an Access app on one of these is a warning only.
OUT_OF_SCOPE=(
  iot.jupiter.au
  ha-mcp.jupiter.au
)

# Healthy tunnels we expect (id → name) for notes only.
declare -A TUNNEL_NAMES=(
  [aa1088b8-a0e1-4073-8567-6a9bf5fb4bd7]=songapp
  [85534a9c-2c13-412c-a658-322f7c36edc7]=jupiter-callisto
  [dea254e7-ef08-4c90-a219-402eb39c7535]=homeassistant
)

usage() {
  cat <<'EOF'
Usage: cloudflare-access-audit.sh [--json] [--no-probe]

  Enumerate zones, DNS CNAMEs to *.cfargotunnel.com, tunnels, and Access apps.
  Classify each tunneled hostname and optionally probe anonymous HTTP.

  --json       print machine-readable JSON summary to stdout (table still on stderr)
  --no-probe   skip curl probes (classification from API only)

Env:
  CLOUDFLARE_API_TOKEN   required
  CLOUDFLARE_ACCOUNT_ID  default 19f62c2ef7861336d274166233ba3a17

Blocked (secured) means anonymous request gets:
  - HTTP 401 or 403, OR
  - HTTP 302/301/303 Location to *.cloudflareaccess.com, OR
  - HTML body containing "Cloudflare Access" / Sign-in Access markers

must-secure additionally requires an Access app with reusable policy
me (b9c394a3-62e9-42e5-8695-7cc2ddfe7ebe). App present but policy me
missing is classified "exposed" and fails the bar.

OUT_OF_SCOPE hostnames (iot/ha-mcp) are enumerated but never gated.
EOF
  exit 2
}

DO_JSON=0
DO_PROBE=1
for arg in "$@"; do
  case "$arg" in
    --json) DO_JSON=1 ;;
    --no-probe) DO_PROBE=0 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $arg" >&2; usage ;;
  esac
done

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  echo "ERROR: CLOUDFLARE_API_TOKEN is required" >&2
  exit 2
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 2
  }
}
need_cmd curl
need_cmd jq

cf_get() {
  local path="$1"
  shift
  curl -sS --fail-with-body --max-time 60 \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "${API_BASE}${path}" "$@"
}

in_list() {
  local needle="$1"
  shift
  local x
  for x in "$@"; do
    [[ "$x" == "$needle" ]] && return 0
  done
  return 1
}

# Returns: blocked|open|unreachable and reason via globals PROBE_STATUS PROBE_REASON PROBE_CODE
probe_host() {
  local host="$1"
  local hdr code loc body
  hdr=$(mktemp)
  PROBE_CODE="000"
  PROBE_STATUS="unreachable"
  PROBE_REASON="curl_failed"

  code=$(curl -sI --max-time 15 -o "$hdr" -w '%{http_code}' "https://${host}/" 2>/dev/null || true)
  [[ -z "$code" ]] && code="000"
  PROBE_CODE="$code"
  loc=$(awk 'BEGIN{IGNORECASE=1} /^[Ll]ocation:/{sub(/\r$/,""); sub(/^[Ll]ocation:[ \t]*/,""); print; exit}' "$hdr" || true)

  if [[ "$code" == "000" ]]; then
    rm -f "$hdr"
    return
  fi

  if [[ "$code" == "401" || "$code" == "403" ]]; then
    PROBE_STATUS="blocked"
    PROBE_REASON="http_${code}"
    rm -f "$hdr"
    return
  fi

  if [[ "$code" == "301" || "$code" == "302" || "$code" == "303" || "$code" == "307" || "$code" == "308" ]]; then
    if echo "$loc" | grep -qi 'cloudflareaccess\.com'; then
      PROBE_STATUS="blocked"
      PROBE_REASON="access_redirect"
      rm -f "$hdr"
      return
    fi
  fi

  body=$(curl -s --max-time 15 "https://${host}/" 2>/dev/null | head -c 2048 || true)
  if echo "$body" | grep -qiE 'Cloudflare Access|Sign in . Cloudflare Access|cloudflareaccess\.com/cdn-cgi/access'; then
    PROBE_STATUS="blocked"
    PROBE_REASON="access_body"
    rm -f "$hdr"
    return
  fi

  PROBE_STATUS="open"
  PROBE_REASON="origin_or_edge"
  rm -f "$hdr"
}

echo "Fetching Cloudflare inventory (account ${ACCOUNT_ID})..." >&2

APPS_JSON=$(cf_get "/accounts/${ACCOUNT_ID}/access/apps")
TUNNELS_JSON=$(cf_get "/accounts/${ACCOUNT_ID}/cfd_tunnel?is_deleted=false&per_page=50")
# Zones for this account (filter by known Jupiter zones if present)
ZONES_JSON=$(cf_get "/zones?per_page=50")

# Build domain → app id map from Access apps, capturing attached policy ids.
# List payload usually embeds .policies; when absent, enrich via per-app GET.
APP_MAP_JSON=$(echo "$APPS_JSON" | jq -c --arg me "$POLICY_ME_ID" '
  [.result[]? | select(.type == "self_hosted" or .type == "ssh" or .type == "vnc") |
    {
      id, name, domain,
      has_me: ([.policies // [] | .[]?.id] | index($me) != null),
      has_svc: ([.policies // [] | .[]? | select(.decision == "non_identity")] | length > 0),
      domains: (
        [(.domain // empty)]
        + (.self_hosted_domains // [])
        + ([.destinations[]? | select(.type=="public") | .uri] // [])
      )
    }
  ] | map(. as $a | .domains[] | {domain: (split("/")[0]), id: $a.id, name: $a.name, has_me: $a.has_me, has_svc: $a.has_svc})
')

# Enrich apps whose list payload omitted policies (fall back to per-app GET).
ENRICHED=()
while IFS= read -r row; do
  [[ -z "$row" ]] && continue
  app_id=$(echo "$row" | jq -r '.id')
  pme=$(echo "$row" | jq -r '.has_me')
  if [[ "$pme" == "false" && -n "$app_id" && "$app_id" != "null" ]]; then
    detail=$(cf_get "/accounts/${ACCOUNT_ID}/access/apps/${app_id}" 2>/dev/null || echo '{}')
    row=$(echo "$detail" | jq -c --argjson old "$row" --arg me "$POLICY_ME_ID" '
      $old + {
        has_me: ([.result.policies // [] | .[]?.id] | index($me) != null),
        has_svc: ([.result.policies // [] | .[]? | select(.decision == "non_identity")] | length > 0)
      }')
  fi
  ENRICHED+=("$row")
done < <(echo "$APP_MAP_JSON" | jq -c '.[]')
if [[ ${#ENRICHED[@]} -gt 0 ]]; then
  APP_MAP_JSON=$(printf '%s\n' "${ENRICHED[@]}" | jq -s -c '.')
else
  APP_MAP_JSON='[]'
fi

# Collect tunnel CNAMEs from all zones
CNAME_ROWS=()
while IFS= read -r zone_id; do
  [[ -z "$zone_id" ]] && continue
  page=1
  while true; do
    dns=$(cf_get "/zones/${zone_id}/dns_records?type=CNAME&per_page=100&page=${page}" || echo '{"result":[]}')
    n=$(echo "$dns" | jq '.result | length')
    while IFS= read -r row; do
      [[ -z "$row" ]] && continue
      CNAME_ROWS+=("$row")
    done < <(echo "$dns" | jq -c '
      .result[]?
      | select((.content // "") | test("\\.cfargotunnel\\.com$"))
      | {name, content, id, zone_id: "'"$zone_id"'"}
    ')
    [[ "$n" -lt 100 ]] && break
    page=$((page + 1))
    [[ $page -gt 20 ]] && break
  done
done < <(echo "$ZONES_JSON" | jq -r '.result[]?.id')

# Tunnel id → status
TUNNEL_STATUS_JSON=$(echo "$TUNNELS_JSON" | jq -c '
  [.result[]? | {id, name, status, connections: ((.connections // []) | length)}]
')

# Healthy tunnel ids currently in account
HEALTHY_TUNNEL_IDS=$(echo "$TUNNEL_STATUS_JSON" | jq -r '.[] | select(.status=="healthy" or .connections > 0) | .id')

classify_one() {
  local host="$1"
  local tunnel_id="$2"
  local app_id="$3"
  local class notes

  notes=""
  if in_list "$host" "${OUT_OF_SCOPE[@]}"; then
    class="out_of_scope"
    notes="out of scope (user decision); Access app removed"
    if [[ -n "$app_id" ]]; then
      notes="${notes}; WARNING Access app still present"
    fi
  elif in_list "$host" "${KNOWN_PUBLIC[@]}"; then
    if [[ -n "$app_id" ]]; then
      class="secured"
      notes="listed-public but Access app present"
    else
      class="public"
      notes="known-public by policy"
    fi
  elif [[ -n "$app_id" ]]; then
    local has_me has_svc
    has_me=$(echo "$APP_MAP_JSON" | jq -r --arg h "$host" --arg id "$app_id" \
      '.[] | select(.domain==$h and .id==$id) | .has_me' | head -1)
    has_svc=$(echo "$APP_MAP_JSON" | jq -r --arg h "$host" --arg id "$app_id" \
      '.[] | select(.domain==$h and .id==$id) | .has_svc' | head -1)
    if [[ "$has_me" == "true" ]]; then
      class="secured"
      notes="access app ${app_id}; policy me"
      [[ "$has_svc" == "true" ]] && notes="${notes}+svc"
    else
      class="exposed"
      notes="access app ${app_id} missing policy me (${POLICY_ME_ID})"
    fi
  else
    # No Access app. Is tunnel live?
    local live=0
    if echo "$HEALTHY_TUNNEL_IDS" | grep -qx "$tunnel_id"; then
      live=1
    fi
    # Also treat unknown tunnel (not in account) as dangling
    local known
    known=$(echo "$TUNNEL_STATUS_JSON" | jq -r --arg id "$tunnel_id" '.[] | select(.id==$id) | .id' | head -1)
    if [[ -z "$known" ]]; then
      class="dangling"
      notes="CNAME to missing/deleted tunnel ${tunnel_id}"
    elif [[ $live -eq 0 ]]; then
      class="dangling"
      notes="tunnel down/inactive ${tunnel_id}"
    else
      class="exposed"
      notes="healthy tunnel, no Access app"
    fi
  fi

  # must-secure without app is always exposed (even if dangling DNS — still a gap)
  if in_list "$host" "${MUST_SECURE[@]}" && [[ "$class" != "secured" ]]; then
    if [[ "$class" == "dangling" ]]; then
      notes="${notes}; must-secure but no DNS/tunnel yet — app should still exist"
      # If must-secure and we have app_id empty, flag as exposed for gate purposes when DNS exists;
      # if no DNS at all this function is only called for tunneled CNAMEs. aeon may have app w/o DNS.
      class="exposed"
    else
      class="exposed"
    fi
  fi

  CLASS="$class"
  NOTES="$notes"
}

# Build rows for every tunnel CNAME
declare -a ROWS=()
EXPOSED_MUST=0
SECURED_FAIL_PROBE=0

for row in "${CNAME_ROWS[@]+"${CNAME_ROWS[@]}"}"; do
  host=$(echo "$row" | jq -r '.name')
  content=$(echo "$row" | jq -r '.content')
  tunnel_id="${content%.cfargotunnel.com}"
  tname=$(echo "$TUNNEL_STATUS_JSON" | jq -r --arg id "$tunnel_id" '.[] | select(.id==$id) | .name' | head -1)
  [[ -z "$tname" || "$tname" == "null" ]] && tname="${TUNNEL_NAMES[$tunnel_id]:-unknown}"

  app_id=$(echo "$APP_MAP_JSON" | jq -r --arg h "$host" '.[] | select(.domain==$h) | .id' | head -1)
  [[ "$app_id" == "null" ]] && app_id=""

  classify_one "$host" "$tunnel_id" "$app_id"
  class="$CLASS"
  notes="$NOTES"

  probe_code=""
  probe_status="skipped"
  probe_reason=""
  if [[ $DO_PROBE -eq 1 ]]; then
    probe_host "$host"
    probe_code="$PROBE_CODE"
    probe_status="$PROBE_STATUS"
    probe_reason="$PROBE_REASON"

    if [[ "$class" == "secured" && "$probe_status" != "blocked" && "$probe_status" != "unreachable" ]]; then
      # Access app exists but anonymous still reaches origin → treat as exposed
      class="exposed"
      notes="${notes}; Access app present but anonymous probe open (${probe_code})"
      SECURED_FAIL_PROBE=$((SECURED_FAIL_PROBE + 1))
    fi
    if [[ "$class" == "secured" && "$probe_status" == "unreachable" ]]; then
      notes="${notes}; probe unreachable (DNS/tunnel gap?)"
    fi
  fi

  if in_list "$host" "${MUST_SECURE[@]}" && [[ "$class" == "exposed" ]]; then
    EXPOSED_MUST=$((EXPOSED_MUST + 1))
  fi

  ROWS+=("$(jq -nc \
    --arg host "$host" \
    --arg tunnel_id "$tunnel_id" \
    --arg tunnel_name "$tname" \
    --arg class "$class" \
    --arg app_id "${app_id:-}" \
    --arg probe_code "${probe_code:-}" \
    --arg probe_status "$probe_status" \
    --arg probe_reason "${probe_reason:-}" \
    --arg notes "$notes" \
    '{host:$host,tunnel_id:$tunnel_id,tunnel_name:$tunnel_name,class:$class,access_app_id:$app_id,
      probe_code:$probe_code,probe_status:$probe_status,probe_reason:$probe_reason,notes:$notes}')")
done

# Also report must-secure hosts that have Access apps but no DNS CNAME (e.g. aeon)
for host in "${MUST_SECURE[@]}"; do
  already=0
  for r in "${ROWS[@]+"${ROWS[@]}"}"; do
    h=$(echo "$r" | jq -r '.host')
    [[ "$h" == "$host" ]] && already=1 && break
  done
  [[ $already -eq 1 ]] && continue

  app_id=$(echo "$APP_MAP_JSON" | jq -r --arg h "$host" '.[] | select(.domain==$h) | .id' | head -1)
  [[ "$app_id" == "null" ]] && app_id=""

  if [[ -n "$app_id" ]]; then
    has_me=$(echo "$APP_MAP_JSON" | jq -r --arg h "$host" --arg id "$app_id" \
      '.[] | select(.domain==$h and .id==$id) | .has_me' | head -1)
    if [[ "$has_me" == "true" ]]; then
      class="secured"
      notes="Access app+me ready; DNS CNAME not present (run: cloudflared tunnel route dns <tunnel> ${host})"
    else
      class="exposed"
      notes="Access app ${app_id} without policy me; no DNS"
      EXPOSED_MUST=$((EXPOSED_MUST + 1))
    fi
  else
    class="exposed"
    notes="must-secure: no DNS and no Access app"
    EXPOSED_MUST=$((EXPOSED_MUST + 1))
  fi

  probe_code=""
  probe_status="skipped"
  probe_reason=""
  if [[ $DO_PROBE -eq 1 ]]; then
    probe_host "$host"
    probe_code="$PROBE_CODE"
    probe_status="$PROBE_STATUS"
    probe_reason="$PROBE_REASON"
  fi

  ROWS+=("$(jq -nc \
    --arg host "$host" \
    --arg class "$class" \
    --arg app_id "${app_id:-}" \
    --arg probe_code "${probe_code:-}" \
    --arg probe_status "$probe_status" \
    --arg probe_reason "${probe_reason:-}" \
    --arg notes "$notes" \
    '{host:$host,tunnel_id:"",tunnel_name:"",class:$class,access_app_id:$app_id,
      probe_code:$probe_code,probe_status:$probe_status,probe_reason:$probe_reason,notes:$notes}')")
done

SUMMARY_JSON=$(printf '%s\n' "${ROWS[@]+"${ROWS[@]}"}" | jq -s \
  --arg account "$ACCOUNT_ID" \
  --argjson exposed_must "$EXPOSED_MUST" \
  --argjson probe_fail "$SECURED_FAIL_PROBE" \
  --argjson must_secure "$(printf '%s\n' "${MUST_SECURE[@]}" | jq -R . | jq -s .)" \
  --argjson known_public "$(printf '%s\n' "${KNOWN_PUBLIC[@]}" | jq -R . | jq -s .)" \
  --argjson out_of_scope "$(printf '%s\n' "${OUT_OF_SCOPE[@]}" | jq -R . | jq -s .)" \
  '{
    account_id: $account,
    must_secure: $must_secure,
    known_public: $known_public,
    out_of_scope: $out_of_scope,
    exposed_must_secure_count: $exposed_must,
    secured_but_open_probe_count: $probe_fail,
    bar_met: ($exposed_must == 0),
    hostnames: .
  }')

# Human table on stderr (or stdout if not --json)
table_out() {
  printf '%-22s %-18s %-10s %-38s %-6s %-12s %s\n' \
    "HOSTNAME" "TUNNEL" "CLASS" "ACCESS_APP_ID" "HTTP" "PROBE" "NOTES"
  printf '%-22s %-18s %-10s %-38s %-6s %-12s %s\n' \
    "----------------------" "------------------" "----------" "--------------------------------------" "------" "------------" "-----"
  echo "$SUMMARY_JSON" | jq -r '.hostnames[] |
    [
      .host,
      (if .tunnel_name != "" then .tunnel_name else "-" end),
      .class,
      (if .access_app_id != "" then .access_app_id else "-" end),
      (if .probe_code != "" then .probe_code else "-" end),
      .probe_status,
      .notes
    ] | @tsv' | while IFS=$'\t' read -r a b c d e f g; do
    printf '%-22s %-18s %-10s %-38s %-6s %-12s %s\n' "$a" "$b" "$c" "$d" "$e" "$f" "$g"
  done
  echo
  echo "must-secure exposed count: $EXPOSED_MUST"
  echo "secured-but-anonymous-open count: $SECURED_FAIL_PROBE"
  if [[ $EXPOSED_MUST -eq 0 ]]; then
    echo "BAR: MET (zero must-secure exposed)"
  else
    echo "BAR: NOT MET"
  fi
}

if [[ $DO_JSON -eq 1 ]]; then
  table_out >&2
  echo "$SUMMARY_JSON"
else
  table_out
fi

# Exit non-zero if any must-secure is exposed
if [[ $EXPOSED_MUST -gt 0 ]]; then
  exit 1
fi
exit 0
