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
# Usage (public image):
#   export IMAGE="library/nginx" TAG="latest"
#   ./docker-pull-curl.sh
#
# Usage (private image with credentials):
#   export IMAGE="myuser/myapp" TAG="v1.2.3"
#   export DOCKER_USER="myuser" DOCKER_PASS="mypassword_or_PAT"
#   ./docker-pull-curl.sh
#
# Usage (via SOCKS5 proxy, e.g. Tor or SSH tunnel):
#   export IMAGE="library/nginx" TAG="latest"
#   export PROXY="socks5h://127.0.0.1:9050"
#   ./docker-pull-curl.sh
#
# For official images the namespace is "library/<name>".
# For user images it's "<user>/<name>".
# For GitHub Packages (ghcr.io), also set:
#   export REGISTRY="ghcr.io" AUTH_URL="https://ghcr.io/token"

set -euo pipefail

# ── Configuration (override via environment) ─────────────────────────
REGISTRY="${REGISTRY:-registry-1.docker.io}"
AUTH_URL="${AUTH_URL:-https://auth.docker.io/token}"
IMAGE="${IMAGE:?Set IMAGE env var (e.g. library/nginx)}"
TAG="${TAG:-latest}"
OUTDIR="${OUTDIR:-layers}"
DOCKER_USER="${DOCKER_USER:-}"          # optional: username
DOCKER_PASS="${DOCKER_PASS:-}"          # optional: password or PAT
# ─────────────────────────────────────────────────────────────────────
# Proxy: curl natively honors ALL_PROXY / HTTPS_PROXY / https_proxy.
# To route through a SOCKS5 proxy (e.g. Tor), just export before running:
#   export ALL_PROXY="socks5h://127.0.0.1:9050"
# No extra flags needed — curl picks it up automatically.
if [[ -n "${ALL_PROXY:-}${HTTPS_PROXY:-}${https_proxy:-}" ]]; then
  echo "==> Proxy detected: ${ALL_PROXY:-${HTTPS_PROXY:-${https_proxy:-}}}"
fi

echo "==> Downloading ${IMAGE}:${TAG} from ${REGISTRY}"

# ── 1. Get an auth token (anonymous or authenticated) ────────────────
echo "--> Requesting auth token..."
auth_args=()
if [[ -n "${DOCKER_USER}" && -n "${DOCKER_PASS}" ]]; then
  echo "    (authenticating as ${DOCKER_USER})"
  auth_args=(-u "${DOCKER_USER}:${DOCKER_PASS}")
fi

token=$(
  curl -sf "${auth_args[@]+"${auth_args[@]}"}" \
    "${AUTH_URL}?service=registry.docker.io&scope=repository:${IMAGE}:pull" \
    | jq -jr '.token'
)

if [[ -z "${token}" || "${token}" == "null" ]]; then
  echo "ERROR: failed to obtain auth token (bad credentials?)"
  exit 1
fi

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
