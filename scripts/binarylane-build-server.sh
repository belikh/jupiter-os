#!/usr/bin/env bash
#
# Drives the ephemeral BinaryLane "rebuild the world" build server end to end:
# create a placeholder server (with every runtime parameter — git ref, host
# list, and every secret the build actually needs — passed as cloud-init
# user_data at create time), upload the pallene ISO as a backup image, attach
# it as boot media, reboot into it, then wait for it to self-destruct
# (modules/services/build-server.nix does that part once it's running).
#
# The pallene ISO itself carries NO secrets and NO per-run parameters — it
# only needs rebuilding when build-server.nix or the pallene host config
# actually change. Every other knob here (which git ref, which hosts, which
# BinaryLane size tier, the whole WireGuard mesh identity) is a plain env
# var to THIS script, no ISO rebuild involved.
#
# BinaryLane has no "create server booting a custom ISO" endpoint — only
# existing servers can have a backup image attached and rebooted into it
# (see the AttachBackup action: "may also be used to boot the server from an
# ISO image"). Hence the two-step dance below instead of one create call.
#
# See docs/europa-bringup-stages.md Stage 4 and
# docs/plans/2026-07-13-001-feat-europa-phase2-tuned-closure-plan.md for the
# full picture.
#
# Usage:
#   BINARYLANE_API_TOKEN=... ATTIC_PUSH_TOKEN=... \
#   R2_ACCOUNT_ID=... R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=... \
#   [WIREGUARD_PRIVATE_KEY=...] [WG_PEER_PUBLIC_KEY=...] [WG_ENDPOINT=...] \
#   [WG_ALLOWED_IPS=cidr1,cidr2] [WG_ADDRESS=...] \
#   [GIT_REF=...] [HOSTS=host1,host2] \
#   ISO_URL=https://... scripts/binarylane-build-server.sh
#
# GIT_REF, HOSTS, REPO_URL, and every WG_*/WIREGUARD_* var are optional —
# omitted, the ISO's own baked defaults apply (see
# modules/services/build-server.nix's defaultRef/hosts/wireguard* options,
# set for pallene in hosts/pallene/configuration.nix).
set -euo pipefail

: "${BINARYLANE_API_TOKEN:?set BINARYLANE_API_TOKEN}"
: "${ATTIC_PUSH_TOKEN:?set ATTIC_PUSH_TOKEN}"
: "${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID}"
: "${R2_ACCESS_KEY_ID:?set R2_ACCESS_KEY_ID}"
: "${R2_SECRET_ACCESS_KEY:?set R2_SECRET_ACCESS_KEY}"
: "${ISO_URL:?set ISO_URL to somewhere BinaryLane can fetch the built pallene ISO over HTTP(S) — a Cloudflare R2 presigned URL (see make pallene-iso)}"

PLACEHOLDER_IMAGE="${BL_PLACEHOLDER_IMAGE:-debian-12}"
HOSTNAME="pallene-run-$(date -u +%Y%m%d%H%M%S 2>/dev/null || echo unknown)"
TIMEOUT_SECS="${TIMEOUT_SECS:-36000}" # 10h primary control — a plain env var, no ISO rebuild to change it.
# Backstop: modules/services/build-server.nix's own in-box timer
# (selfDestructCeilingHours, baked at ISO build time) independently
# force-destroys the server if it's still alive past ITS ceiling — keep that
# NixOS option's default comfortably above whatever TIMEOUT_SECS you use
# here, or the in-box timer silently wins and kills a still-progressing run.

api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -X "$method" "https://api.binarylane.com.au$path" \
    -H "Authorization: Bearer $BINARYLANE_API_TOKEN")
  [ -n "$body" ] && args+=(-H "Content-Type: application/json" -d "$body")
  curl "${args[@]}"
}

wait_action() {
  local action_id="$1"
  echo ">> waiting on action $action_id..."
  while true; do
    status="$(api GET "/v2/actions/$action_id" | jq -r '.action.status')"
    case "$status" in
      completed) echo ">> action $action_id completed"; return 0 ;;
      errored) echo "!! action $action_id errored" >&2; return 1 ;;
      *) sleep 5 ;;
    esac
  done
}

# --- runtime parameters, as cloud-init user_data --------------------------
# Plain `KEY=value` lines — build-server.nix's runScript reads this back
# directly from cloud-init's cached /var/lib/cloud/instance/user-data.txt (no
# YAML/write_files involved, matching the one mechanism the ISO already
# proved out for the git ref alone). Only emit a line when the var is
# actually set, so an omitted GIT_REF/HOSTS/REPO_URL cleanly falls through to
# the ISO's own baked defaults instead of sending an empty override.
build_user_data() {
  local out=""
  add() { [ -n "${2:-}" ] && out+="$1=$2"$'\n'; }
  add GIT_REF "${GIT_REF:-}"
  add REPO_URL "${REPO_URL:-}"
  add HOSTS "${HOSTS:-}"
  add BINARYLANE_API_TOKEN "$BINARYLANE_API_TOKEN"
  add ATTIC_PUSH_TOKEN "$ATTIC_PUSH_TOKEN"
  add R2_ACCOUNT_ID "$R2_ACCOUNT_ID"
  add R2_ACCESS_KEY_ID "$R2_ACCESS_KEY_ID"
  add R2_SECRET_ACCESS_KEY "$R2_SECRET_ACCESS_KEY"
  add WIREGUARD_PRIVATE_KEY "${WIREGUARD_PRIVATE_KEY:-}"
  # Rest of the mesh identity — not secret (a public key and a hostname),
  # but override-able for the same reason GIT_REF/HOSTS are: change the mesh
  # topology without an ISO rebuild. Omitted, the ISO's own baked defaults
  # (hosts/pallene/configuration.nix) apply — same values as today.
  add WG_PEER_PUBLIC_KEY "${WG_PEER_PUBLIC_KEY:-}"
  add WG_ENDPOINT "${WG_ENDPOINT:-}"
  add WG_ALLOWED_IPS "${WG_ALLOWED_IPS:-}"
  add WG_ADDRESS "${WG_ADDRESS:-}"
  printf '%s' "$out"
}
USER_DATA="$(build_user_data)"
echo ">> runtime parameters prepared: $(printf '%s' "$USER_DATA" | cut -d= -f1 | tr '\n' ' ')"

# Candidate regions, in priority order (lowest-latency-to-home first, then
# the rest of domestic AU). A cheaper size tier being out of capacity in the
# primary region is common (observed 2026-07-17/18) — checking the SAME
# cheap tier in the other AU regions first, before ever escalating to a
# pricier tier, is strictly cheaper when it works. Adelaide/Perth are
# smaller, less contended markets — worth trying before giving up on a cheap
# tier entirely. Singapore deliberately excluded by default (international,
# real latency to the home mesh); override with BL_REGION_SLUGS
# (space-separated) to include it or change the set/order, or BL_REGION_SLUG
# for the old single-region behaviour.
if [ -n "${BL_REGION_SLUG:-}" ]; then
  REGION_SLUGS="$BL_REGION_SLUG"
elif [ -n "${BL_REGION_SLUGS:-}" ]; then
  REGION_SLUGS="$BL_REGION_SLUGS"
else
  regions_json="$(api GET /v2/regions)"
  REGION_SLUGS="$(for name in melbourne brisbane sydney adelaide perth; do
    jq -r --arg n "$name" '[.regions[] | select(.available) | select(.name | test($n; "i"))][0].slug // empty' <<<"$regions_json"
  done | grep -v '^$')"
fi
[ -n "$REGION_SLUGS" ] || { echo "!! no available AU region found via /v2/regions — set BL_REGION_SLUGS" >&2; exit 1; }
echo ">> candidate regions, in order: $(echo "$REGION_SLUGS" | tr '\n' ' ')"

# Build the (size, region) plan: every "CPU Optimised"-class size (>=8 vcpus,
# >=16GB) available in ANY candidate region, cheapest size first — and within
# a size, candidate regions in priority order — so the plan always tries the
# globally cheapest option before anything pricier. BinaryLane's own size
# catalog can list a tier as available while actual capacity is exhausted —
# server creation then fails with a 400 "Unable to find a suitable host for
# the requested server configuration" (observed 2026-07-17). Set
# BL_SIZE_SLUG to skip this entirely and force one exact slug (still tried
# across every candidate region in order).
sizes_json="$(api GET /v2/sizes)"
if [ -n "${BL_SIZE_SLUG:-}" ]; then
  size_slugs="$BL_SIZE_SLUG"
else
  size_slugs="$(jq -r '
    [.sizes[] | select(.available) | select(.vcpus >= 8 and .memory >= 16384 and .disk >= 300)]
    | sort_by(.price_monthly) | unique_by(.slug) | .[].slug' <<<"$sizes_json")"
  # std-8vcpu is nominally pricier than cpu-8thr (~9%) but has double the RAM
  # (32GB vs 16GB) and more disk (340GB vs 300GB) — genuinely worth more on
  # this workload specifically: pallene is a live-ISO builder running
  # /nix/store + /tmp entirely on tmpfs, so the closure has to fit in
  # RAM+swap just to EXIST regardless of compile-time pressure, and more real
  # RAM (vs swap-on-disk I/O) measurably speeds that up. cpu-8thr also kept
  # hitting capacity failures in practice (2026-07-17/18) while std-8vcpu had
  # room. Promote it ahead of cpu-8thr specifically rather than trusting pure
  # price-sort for this one pair.
  if grep -qx 'std-8vcpu' <<<"$size_slugs" && grep -qx 'cpu-8thr' <<<"$size_slugs"; then
    size_slugs="$(awk '$0=="std-8vcpu"{next} $0=="cpu-8thr"{print "std-8vcpu"; print; next} {print}' <<<"$size_slugs")"
  fi
fi
[ -n "$size_slugs" ] || { echo "!! no matching >=8vcpu/16GB/300GB size found via /v2/sizes — set BL_SIZE_SLUG" >&2; exit 1; }

plan=""
while IFS= read -r size_slug; do
  [ -n "$size_slug" ] || continue
  while IFS= read -r region_slug; do
    [ -n "$region_slug" ] || continue
    if jq -e --arg s "$size_slug" --arg r "$region_slug" \
        '.sizes[] | select(.slug == $s) | .regions | index($r)' <<<"$sizes_json" >/dev/null 2>&1; then
      plan+="$size_slug $region_slug"$'\n'
    fi
  done <<<"$REGION_SLUGS"
done <<<"$size_slugs"
[ -n "$plan" ] || { echo "!! no (size, region) combination available across candidate regions" >&2; exit 1; }

server_id=""
while IFS=' ' read -r size_slug region_slug; do
  [ -n "$size_slug" ] || continue
  echo ">> creating placeholder server ($HOSTNAME, $size_slug in $region_slug)..."
  create_resp="$(api POST /v2/servers "$(jq -n \
    --arg name "$HOSTNAME" --arg size "$size_slug" --arg region "$region_slug" \
    --arg image "$PLACEHOLDER_IMAGE" --arg userdata "$USER_DATA" \
    '{name: $name, size: $size, region: $region, image: $image, user_data: $userdata}')")"
  server_id="$(jq -r '.server.id // empty' <<<"$create_resp")"
  if [ -n "$server_id" ]; then
    echo ">> server id=$server_id created ($size_slug in $region_slug)"
    break
  fi
  echo "!! create failed on $size_slug/$region_slug: $(jq -c '.detail // .message // .' <<<"$create_resp" 2>/dev/null || echo "$create_resp") — trying next" >&2
done <<<"$plan"
[ -n "$server_id" ] || { echo "!! server create failed on every (size, region) combination tried:"$'\n'"$plan" >&2; exit 1; }

echo ">> waiting for server to become active..."
while [ "$(api GET "/v2/servers/$server_id" | jq -r '.server.status')" != "active" ]; do sleep 5; done

echo ">> uploading pallene ISO as a backup image from $ISO_URL..."
upload_resp="$(api POST "/v2/servers/$server_id/backups" "$(jq -n --arg url "$ISO_URL" \
  '{url: $url, backup_type: "temporary", replacement_strategy: "none"}')")"
upload_action_id="$(jq -r '.action.id' <<<"$upload_resp")"
wait_action "$upload_action_id"

image_id="$(api GET "/v2/servers/$server_id/backups" | jq -r '.backups[0].id')"
[ -n "$image_id" ] && [ "$image_id" != "null" ] || { echo "!! could not find uploaded backup image id" >&2; exit 1; }
echo ">> uploaded image id=$image_id"

echo ">> attaching ISO as boot media and rebooting..."
attach_resp="$(api POST "/v2/servers/$server_id/actions" "$(jq -n --argjson image "$image_id" \
  '{type: "attach_backup", image: $image}')")"
wait_action "$(jq -r '.action.id' <<<"$attach_resp")"

reboot_resp="$(api POST "/v2/servers/$server_id/actions" '{"type": "reboot"}')"
wait_action "$(jq -r '.action.id' <<<"$reboot_resp")"

echo ">> booted into pallene ISO — build-server.nix's own systemd service takes it"
echo ">> from here, driven entirely by the user_data sent at create time."
echo ">> waiting up to ${TIMEOUT_SECS}s for the server to delete itself..."

deadline=$((SECONDS + TIMEOUT_SECS))
while ((SECONDS < deadline)); do
  http_code="$(curl -sS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $BINARYLANE_API_TOKEN" \
    "https://api.binarylane.com.au/v2/servers/$server_id")"
  if [ "$http_code" = "404" ]; then
    echo ">> server $server_id is gone — rebuild-the-world run finished and self-destructed cleanly."
    exit 0
  fi
  sleep 30
done

echo "!! server $server_id did not self-destruct within ${TIMEOUT_SECS}s — force-destroying now" >&2
api DELETE "/v2/servers/$server_id?reason=CI+timeout+force+destroy" || true
echo "!! this means the run hung or crashed before its own self-destruct fired — check billing and logs." >&2
exit 1
