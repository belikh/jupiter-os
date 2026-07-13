#!/usr/bin/env bash
#
# Drives the ephemeral BinaryLane "rebuild the world" build server end to end:
# create a placeholder server, upload the pallene ISO as a backup image,
# attach it as boot media, reboot into it, then wait for it to self-destruct
# (modules/services/build-server.nix does that part once it's running).
#
# BinaryLane has no "create server booting a custom ISO" endpoint — only
# existing servers can have a backup image attached and rebooted into it
# (see the AttachBackup action: "may also be used to boot the server from an
# ISO image"). Hence the two-step dance below instead of one create call.
#
# See docs/europa-bringup-stages.md Stage 4 and
# docs/plans/2026-07-13-001-feat-europa-phase2-tuned-closure-plan.md for the
# full picture, including which env vars need real account values before this
# can run for real.
#
# Usage: BINARYLANE_API_TOKEN=... ISO_URL=https://... scripts/binarylane-build-server.sh
set -euo pipefail

: "${BINARYLANE_API_TOKEN:?set BINARYLANE_API_TOKEN}"
: "${ISO_URL:?set ISO_URL to somewhere BinaryLane can fetch the built pallene ISO over HTTP(S) — a Cloudflare R2 presigned URL (see make pallene-iso)}"

PLACEHOLDER_IMAGE="${BL_PLACEHOLDER_IMAGE:-debian-12}"
HOSTNAME="pallene-run-$(date -u +%Y%m%d%H%M%S 2>/dev/null || echo unknown)"
GIT_REF="${GIT_REF:-dashboard-v2}"
TIMEOUT_SECS="${TIMEOUT_SECS:-14400}" # 4h, matches the ISO's own force-destroy timer

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

# Resolve region/size by human-readable criteria against the live account
# instead of hardcoding slugs, which BinaryLane can renumber/rename. Override
# with BL_REGION_SLUG/BL_SIZE_SLUG if this ever picks the wrong one.
REGION_SLUG="${BL_REGION_SLUG:-$(api GET /v2/regions | jq -r '
  [.regions[] | select(.available) | select(.name | test("melbourne"; "i"))][0].slug // empty')}"
[ -n "$REGION_SLUG" ] || { echo "!! no available Melbourne region found via /v2/regions — set BL_REGION_SLUG" >&2; exit 1; }

# The "CPU Optimised" 8-thread/16GB/300-600GB NVMe tier is the target: pick
# the cheapest size with >=8 vcpus, >=16GB memory, and >=300GB disk available
# in $REGION_SLUG.
SIZE_SLUG="${BL_SIZE_SLUG:-$(api GET /v2/sizes | jq -r --arg region "$REGION_SLUG" '
  [.sizes[] | select(.available) | select(.regions | index($region))
    | select(.vcpus >= 8 and .memory >= 16384 and .disk >= 300)]
  | sort_by(.price_monthly)[0].slug // empty')}"
[ -n "$SIZE_SLUG" ] || { echo "!! no matching >=8vcpu/16GB/300GB size found via /v2/sizes in $REGION_SLUG — set BL_SIZE_SLUG" >&2; exit 1; }

echo ">> creating placeholder server ($HOSTNAME, $SIZE_SLUG in $REGION_SLUG)..."
create_resp="$(api POST /v2/servers "$(jq -n \
  --arg name "$HOSTNAME" --arg size "$SIZE_SLUG" --arg region "$REGION_SLUG" --arg image "$PLACEHOLDER_IMAGE" \
  '{name: $name, size: $size, region: $region, image: $image}')")"
server_id="$(jq -r '.server.id' <<<"$create_resp")"
[ -n "$server_id" ] && [ "$server_id" != "null" ] || { echo "!! server create failed: $create_resp" >&2; exit 1; }
echo ">> server id=$server_id created"

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
echo ">> from here (clone @ $GIT_REF, rebuild the world, push to attic, self-destruct)."
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
