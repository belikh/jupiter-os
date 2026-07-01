#!/usr/bin/env bash
#
# Uploads the pallene ISO (built by `make pallene-iso` into result/iso/*.iso)
# to the Cloudflare R2 bucket terraform/cloudflare provisions
# (cloudflare_r2_bucket.pallene_iso), then prints a presigned HTTPS URL on
# stdout that BinaryLane's AttachBackup call can fetch it from (see
# scripts/binarylane-build-server.sh's ISO_URL) without making the bucket
# public. R2 is S3-compatible, so this is just awscli pointed at R2's
# per-account endpoint.
#
# Required env: AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (an R2 API token
# scoped to Object Read & Write on the bucket below), R2_ACCOUNT_ID
# (Cloudflare account id).
#
# Usage: R2_ACCOUNT_ID=... AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... \
#          scripts/upload-pallene-iso-r2.sh
set -euo pipefail

: "${AWS_ACCESS_KEY_ID:?set AWS_ACCESS_KEY_ID to an R2 access key id}"
: "${AWS_SECRET_ACCESS_KEY:?set AWS_SECRET_ACCESS_KEY to an R2 secret access key}"
: "${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID to the Cloudflare account id}"

BUCKET="${R2_BUCKET:-jupiter-os-pallene-iso}"
# Matches the ISO's own 4h force-destroy timer (modules/services/build-server.nix) —
# no point in a presigned URL outliving the run it's for.
EXPIRES_SECS="${PRESIGN_EXPIRES_SECS:-14400}"
ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

iso_path="$(find result/iso -maxdepth 1 -name '*.iso' -print -quit 2>/dev/null || true)"
[ -n "$iso_path" ] || { echo "!! no ISO found under result/iso/ — run 'make pallene-iso' first" >&2; exit 1; }

key="pallene-$(date -u +%Y%m%d%H%M%S).iso"

echo ">> uploading $iso_path to r2://$BUCKET/$key..." >&2
aws --endpoint-url "$ENDPOINT" s3 cp "$iso_path" "s3://$BUCKET/$key" >&2

aws --endpoint-url "$ENDPOINT" s3 presign "s3://$BUCKET/$key" --expires-in "$EXPIRES_SECS"
