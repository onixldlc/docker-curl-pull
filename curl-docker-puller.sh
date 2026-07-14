#!/usr/bin/env bash
# docker-pull-curl.sh
# Manually download a Docker Hub container image using only curl & jq,
# then load it into docker — no `docker pull` required.
#
# Based on: https://tech.michaelaltfield.net/2024/09/03/container-download-curl-wget/
# OCI Distribution Spec v1.1.0
#
# Requirements: curl, jq, docker (for the final load step)
#
# Usage:
#   export IMAGE="library/hitch"
#   export TAG="1.8.0-1"
#   ./docker-pull-curl.sh
#
# For official images the namespace is "library/<name>".
# For user images it's "<user>/<name>".

set -euo pipefail

# ── Configuration (override via environment) ─────────────────────────
REGISTRY="${REGISTRY:-registry-1.docker.io}"
AUTH_URL="${AUTH_URL:-https://auth.docker.io/token}"
IMAGE="${IMAGE:?Set IMAGE env var (e.g. library/nginx)}"
TAG="${TAG:-latest}"
OUTDIR="${OUTDIR:-layers}"
# ─────────────────────────────────────────────────────────────────────

echo "==> Downloading ${IMAGE}:${TAG} from ${REGISTRY}"

# ── 1. Get an anonymous auth token ───────────────────────────────────
echo "--> Requesting auth token..."
token=$(
  curl -sf "${AUTH_URL}?service=registry.docker.io&scope=repository:${IMAGE}:pull" \
    | jq -jr '.token'
)

# ── 2. (Optional) List available tags ────────────────────────────────
echo "--> Verifying tag '${TAG}' exists..."
curl -sf \
  -H "Authorization: Bearer ${token}" \
  "https://${REGISTRY}/v2/${IMAGE}/tags/list" \
  | jq -e --arg t "${TAG}" '.tags | index($t)' > /dev/null \
  || { echo "ERROR: tag '${TAG}' not found"; exit 1; }

# ── 3. Download the manifest ────────────────────────────────────────
echo "--> Downloading manifest..."
curl -sf \
  -H "Authorization: Bearer ${token}" \
  "https://${REGISTRY}/v2/${IMAGE}/manifests/${TAG}" \
  -o manifest.json

# ── 4. Download every layer ──────────────────────────────────────────
num_layers=$(jq '.history | length' manifest.json)
echo "--> Image has ${num_layers} layers"

rm -rf "${OUTDIR}"
mkdir -p "${OUTDIR}"

for (( i = 0; i < num_layers; i++ )); do
  blob_sum=$(jq -r ".fsLayers[$i].blobSum"        manifest.json)
  metadata=$(jq -r  ".history[$i].v1Compatibility" manifest.json)
  layer_id=$(echo "${metadata}" | jq -r '.id')

  echo "    layer $((i+1))/${num_layers}  ${layer_id:0:12}...  ${blob_sum:7:12}..."

  mkdir -p "${OUTDIR}/${layer_id}"
  echo "1.0"        > "${OUTDIR}/${layer_id}/VERSION"
  echo "${metadata}" > "${OUTDIR}/${layer_id}/json"

  curl -#L \
    -H "Authorization: Bearer ${token}" \
    "https://${REGISTRY}/v2/${IMAGE}/blobs/${blob_sum}" \
    -o "${OUTDIR}/${layer_id}/layer.tar"
done

# ── 5. Create the repositories file ─────────────────────────────────
start_id=$(
  jq -r '.history[0].v1Compatibility' manifest.json | jq -r '.id'
)
short_name="${IMAGE##*/}"

cat > "${OUTDIR}/repositories" <<EOF
{"${short_name}":{"${TAG}":"${start_id}"}}
EOF

echo "--> repositories file created (${short_name}:${TAG})"

# ── 6. Load into docker ─────────────────────────────────────────────
echo "==> Loading image into docker..."
tar -cC "${OUTDIR}" . | docker image load

echo "==> Done!  Run:  docker image ls ${short_name}"