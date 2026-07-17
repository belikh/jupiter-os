#!/usr/bin/env bash
#
# Uploads the pallene ISO (built by `make pallene-iso` into result/iso/*.iso)
# to the Cloudflare R2 bucket "jupiter-os-pallene-iso", then prints a
# presigned HTTPS URL on stdout that BinaryLane's backup-image API can fetch
# the ISO from (see scripts/binarylane-build-server.sh's ISO_URL) without
# making the bucket public. R2 is S3-compatible, so this is just awscli
# pointed at R2's per-account endpoint.
#
# R2 free tier covers this comfortably: the ISO is ~1 GB (well under the 10
# GB-month free storage), one PUT + one GET per run (well under the 1M/10M
# operation allowances), and R2 has zero egress — BinaryLane's ~1 GB download
# costs nothing.
#
# Bucket provisioning (one-time, manual): create the bucket
# "jupiter-os-pallene-iso" in the Cloudflare dashboard (R2), then create an
# R2 API token scoped to Object Read & Write on that bucket — the token's
# Access Key ID / Secret Access Key go into sops as r2_access_key_id /
# r2_secret_access_key, and the Cloudflare account id as cloudflare_account_id.
#
# Required env: AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (the R2 API token),
# R2_ACCOUNT_ID (Cloudflare account id).
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

key="pallene.iso"

echo ">> uploading $iso_path to r2://$BUCKET/$key..." >&2
# --region auto is mandatory for R2: without it awscli defaults to a
# SigV2 presigned URL ("AWSAccessKeyId=…") which R2 rejects with 401 (R2 is
# SigV4-only), so BinaryLane's image-fetch would fail in ~2s. region=auto
# forces SigV4 ("X-Amz-Algorithm=…"), which R2 serves correctly.
aws --endpoint-url "$ENDPOINT" s3 cp "$iso_path" "s3://$BUCKET/$key" --region auto >&2

aws --endpoint-url "$ENDPOINT" s3 presign "s3://$BUCKET/$key" --expires-in "$EXPIRES_SECS" --region auto
