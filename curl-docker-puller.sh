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
#   export ALL_PROXY="socks5h://127.0.0.1:9050"
#   export IMAGE="library/nginx" TAG="latest"
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
auth_url_full="${AUTH_URL}?service=registry.docker.io&scope=repository:${IMAGE}:pull"
echo "--> Requesting auth token..."
echo "    URL: ${auth_url_full}"

auth_args=()
if [[ -n "${DOCKER_USER}" && -n "${DOCKER_PASS}" ]]; then
  echo "    (authenticating as ${DOCKER_USER})"
  auth_args=(-u "${DOCKER_USER}:${DOCKER_PASS}")
fi

http_code=$(
  curl -sS -w '%{http_code}' -o /tmp/token_response.json \
    "${auth_args[@]+"${auth_args[@]}"}" \
    "${auth_url_full}" \
    2>/tmp/curl_err.log
) || {
  echo "ERROR: curl failed on token request"
  echo "--- curl stderr ---"
  cat /tmp/curl_err.log
  exit 1
}

echo "    HTTP ${http_code}"

if [[ "${http_code}" -ge 400 ]]; then
  echo "ERROR: token request returned HTTP ${http_code}"
  echo "--- response body ---"
  cat /tmp/token_response.json
  exit 1
fi

token=$(jq -jr '.token // empty' /tmp/token_response.json)

if [[ -z "${token}" ]]; then
  echo "ERROR: no token in response"
  echo "--- response body ---"
  cat /tmp/token_response.json
  exit 1
fi

echo "    token acquired (${#token} chars)"

# ── 2. Verify the tag exists ──────────────────────────────────────────
echo "--> Verifying tag '${TAG}' exists..."
tags_url="https://${REGISTRY}/v2/${IMAGE}/tags/list"
echo "    URL: ${tags_url}"

http_code=$(
  curl -sS -w '%{http_code}' -o /tmp/tags_response.json \
    -H "Authorization: Bearer ${token}" \
    "${tags_url}" \
    2>/tmp/curl_err.log
) || {
  echo "ERROR: curl failed on tags request"
  echo "--- curl stderr ---"
  cat /tmp/curl_err.log
  exit 1
}

echo "    HTTP ${http_code}"

if [[ "${http_code}" -ge 400 ]]; then
  echo "ERROR: tags request returned HTTP ${http_code}"
  echo "--- response body ---"
  cat /tmp/tags_response.json
  exit 1
fi

if ! jq -e --arg t "${TAG}" '.tags | index($t)' /tmp/tags_response.json > /dev/null 2>&1; then
  echo "ERROR: tag '${TAG}' not found in repository"
  echo "    available tags: $(jq -r '.tags[:10] | join(", ")' /tmp/tags_response.json 2>/dev/null || echo '(could not parse)')"
  exit 1
fi

# ── 3. Download the manifest ────────────────────────────────────────
manifest_url="https://${REGISTRY}/v2/${IMAGE}/manifests/${TAG}"
echo "--> Downloading manifest..."
echo "    URL: ${manifest_url}"

http_code=$(
  curl -sS -w '%{http_code}' -o manifest.json \
    -H "Authorization: Bearer ${token}" \
    "${manifest_url}" \
    2>/tmp/curl_err.log
) || {
  echo "ERROR: curl failed on manifest request"
  echo "--- curl stderr ---"
  cat /tmp/curl_err.log
  exit 1
}

echo "    HTTP ${http_code}"

if [[ "${http_code}" -ge 400 ]]; then
  echo "ERROR: manifest request returned HTTP ${http_code}"
  echo "--- response body ---"
  cat manifest.json
  exit 1
fi

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
