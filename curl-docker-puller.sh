#!/usr/bin/env bash
# docker-pull-curl.sh
# Manually download a container image using only curl & jq, then load it
# into docker — no `docker pull` required.
#
# Based on: https://tech.michaelaltfield.net/2024/09/03/container-download-curl-wget/
# ...but updated to handle the modern OCI format that registries actually
# serve today: an "image index" (multi-arch manifest list) pointing to
# per-platform "image manifests" (schema 2), which use .config + .layers[]
# instead of the legacy schema-1 .fsLayers[] / .history[] arrays.
#
# Requirements: curl, jq, docker (for the final load step)
#
# Usage (public image):
#   export IMAGE="library/nginx" TAG="latest"
#   ./docker-pull-curl.sh
#
# Usage (pick a platform, default linux/amd64):
#   export IMAGE="library/nginx" TAG="latest" ARCH="arm64" OS="linux"
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
#   export REGISTRY="ghcr.io" AUTH_URL="https://ghcr.io/token" AUTH_SERVICE="ghcr.io"

set -euo pipefail

# ── Configuration (override via environment) ─────────────────────────
REGISTRY="${REGISTRY:-registry-1.docker.io}"
AUTH_URL="${AUTH_URL:-https://auth.docker.io/token}"
AUTH_SERVICE="${AUTH_SERVICE:-registry.docker.io}"
IMAGE="${IMAGE:?Set IMAGE env var (e.g. library/nginx)}"
TAG="${TAG:-latest}"
ARCH="${ARCH:-amd64}"                   # target architecture
OS="${OS:-linux}"                       # target OS
OUTDIR="${OUTDIR:-layers}"
DOCKER_USER="${DOCKER_USER:-}"          # optional: username
DOCKER_PASS="${DOCKER_PASS:-}"          # optional: password or PAT
# ─────────────────────────────────────────────────────────────────────

# OCI / docker media types we accept when requesting a manifest.
ACCEPT_MANIFEST=(
  -H 'Accept: application/vnd.oci.image.index.v1+json'
  -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json'
  -H 'Accept: application/vnd.oci.image.manifest.v1+json'
  -H 'Accept: application/vnd.docker.distribution.manifest.v2+json'
)

# Proxy: curl natively honors ALL_PROXY / HTTPS_PROXY / https_proxy.
if [[ -n "${ALL_PROXY:-}${HTTPS_PROXY:-}${https_proxy:-}" ]]; then
  echo "==> Proxy detected: ${ALL_PROXY:-${HTTPS_PROXY:-${https_proxy:-}}}"
fi

echo "==> Downloading ${IMAGE}:${TAG} (${OS}/${ARCH}) from ${REGISTRY}"

# ── Helper: authenticated GET with full error reporting ──────────────
# Usage: registry_get <url> <output_file> [extra curl args...]
# Echoes the HTTP status code; dumps stderr + body and exits on failure.
registry_get() {
  local url="$1" out="$2"; shift 2
  local code
  code=$(
    curl -sSL -w '%{http_code}' -o "${out}" \
      -H "Authorization: Bearer ${token}" \
      "$@" \
      "${url}" \
      2>/tmp/curl_err.log
  ) || {
    echo "ERROR: curl failed requesting ${url}" >&2
    echo "--- curl stderr ---" >&2
    cat /tmp/curl_err.log >&2
    exit 1
  }
  if [[ "${code}" -ge 400 ]]; then
    echo "ERROR: HTTP ${code} requesting ${url}" >&2
    echo "--- response body ---" >&2
    cat "${out}" >&2
    exit 1
  fi
  echo "${code}"
}

# ── 1. Get an auth token (anonymous or authenticated) ────────────────
auth_url_full="${AUTH_URL}?service=${AUTH_SERVICE}&scope=repository:${IMAGE}:pull"
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
  echo "--- curl stderr ---"; cat /tmp/curl_err.log
  exit 1
}
echo "    HTTP ${http_code}"

if [[ "${http_code}" -ge 400 ]]; then
  echo "ERROR: token request returned HTTP ${http_code}"
  echo "--- response body ---"; cat /tmp/token_response.json
  exit 1
fi

token=$(jq -jr '.token // .access_token // empty' /tmp/token_response.json)
if [[ -z "${token}" ]]; then
  echo "ERROR: no token in response"
  echo "--- response body ---"; cat /tmp/token_response.json
  exit 1
fi
echo "    token acquired (${#token} chars)"

# ── 2. Download the top-level manifest ───────────────────────────────
manifest_url="https://${REGISTRY}/v2/${IMAGE}/manifests/${TAG}"
echo "--> Downloading manifest for tag '${TAG}'..."
echo "    URL: ${manifest_url}"
code=$(registry_get "${manifest_url}" index.json "${ACCEPT_MANIFEST[@]}")
echo "    HTTP ${code}"

media_type=$(jq -r '.mediaType // empty' index.json)
echo "    mediaType: ${media_type:-<none>}"

# ── 3. If it's an index/list, resolve to a single image manifest ─────
case "${media_type}" in
  *image.index*|*manifest.list*)
    echo "--> Multi-arch index; selecting ${OS}/${ARCH}..."
    digest=$(
      jq -r --arg arch "${ARCH}" --arg os "${OS}" '
        .manifests[]
        | select(.platform.architecture == $arch and .platform.os == $os)
        # skip attestation manifests (they have no real platform)
        | select(.annotations["vnd.docker.reference.type"] != "attestation-manifest")
        | .digest
      ' index.json | head -n1
    )
    if [[ -z "${digest}" ]]; then
      echo "ERROR: no image manifest for ${OS}/${ARCH} in this index"
      echo "    available platforms:"
      jq -r '.manifests[].platform | "      - \(.os // "?")/\(.architecture // "?")\(if .variant then "/"+.variant else "" end)"' index.json | sort -u
      exit 1
    fi
    echo "    selected digest: ${digest:7:19}..."
    img_manifest_url="https://${REGISTRY}/v2/${IMAGE}/manifests/${digest}"
    code=$(registry_get "${img_manifest_url}" manifest.json "${ACCEPT_MANIFEST[@]}")
    echo "    HTTP ${code}"
    ;;
  *)
    # Already a single image manifest.
    cp index.json manifest.json
    ;;
esac

img_media_type=$(jq -r '.mediaType // empty' manifest.json)

# Guard against ancient schema-1 (no .config); we only support schema 2 / OCI.
if ! jq -e '.config.digest' manifest.json >/dev/null 2>&1; then
  echo "ERROR: manifest has no .config (schema-1 or unexpected format: ${img_media_type})"
  echo "--- manifest ---"; cat manifest.json
  exit 1
fi

# ── 4. Build a docker-loadable layout (Image Spec v1.2 / manifest.json) ─
rm -rf "${OUTDIR}"
mkdir -p "${OUTDIR}"

# 4a. Download the image config (the JSON blob docker uses for the image).
config_digest=$(jq -r '.config.digest' manifest.json)
config_file="${config_digest#sha256:}.json"
echo "--> Downloading image config ${config_digest:7:19}..."
code=$(registry_get \
  "https://${REGISTRY}/v2/${IMAGE}/blobs/${config_digest}" \
  "${OUTDIR}/${config_file}" \
  -H 'Accept: application/vnd.oci.image.config.v1+json')
echo "    HTTP ${code}"

# 4b. Download each layer blob, named <digest>.tar inside OUTDIR.
num_layers=$(jq '.layers | length' manifest.json)
echo "--> Image has ${num_layers} layer(s)"

layer_files=()
for (( i = 0; i < num_layers; i++ )); do
  l_digest=$(jq -r ".layers[$i].digest"    manifest.json)
  l_type=$(  jq -r ".layers[$i].mediaType" manifest.json)
  l_file="${l_digest#sha256:}.tar"
  layer_files+=("${l_file}")

  echo "    layer $((i+1))/${num_layers}  ${l_digest:7:19}...  (${l_type})"
  code=$(registry_get \
    "https://${REGISTRY}/v2/${IMAGE}/blobs/${l_digest}" \
    "${OUTDIR}/${l_file}" \
    -#L)
  echo "      HTTP ${code}  size: $(du -h "${OUTDIR}/${l_file}" | cut -f1)"
done

# 4c. Write the manifest.json that `docker load` reads.
#     RepoTags ties the image to a name:tag so it shows up in `docker image ls`.
repo_tag="${IMAGE##library/}"          # drop "library/" for official images
repo_tag="${repo_tag}:${TAG}"

layers_json=$(printf '%s\n' "${layer_files[@]}" | jq -R . | jq -s .)
jq -n \
  --arg config "${config_file}" \
  --arg tag "${repo_tag}" \
  --argjson layers "${layers_json}" \
  '[{Config: $config, RepoTags: [$tag], Layers: $layers}]' \
  > "${OUTDIR}/manifest.json"

echo "--> Wrote docker load manifest (${repo_tag})"

# ── 5. Load into docker ──────────────────────────────────────────────
echo "==> Loading image into docker..."
tar -cC "${OUTDIR}" . | docker image load

echo "==> Done!  Run:  docker image ls ${repo_tag%%:*}"
