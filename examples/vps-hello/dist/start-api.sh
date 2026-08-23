#!/usr/bin/env bash
# Generic API start — generated into product dist by vibed-infra package.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=lib-env.sh
[[ -f lib-env.sh ]] && source lib-env.sh && load_dotenv .env

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi

IMAGE="${BACKEND_IMAGE:-ghcr.io/example/api:main}"
NAME="${DOCKER_NAME:-app-api}"
HOST_PORT="${HOST_PORT:-8080}"
DATA_DIR="${DATA_DIR:-./data}"
NETWORK="${DOCKER_NETWORK:-app-edge}"
CONFIG="${CONFIG_FILE:-api-app.yaml}"
MEMORY="${API_MEMORY_LIMIT:-256m}"

if [[ ! -f "$CONFIG" ]]; then
  echo "Missing $CONFIG — run install-api.sh first." >&2
  exit 1
fi

if [[ "${PULL:-1}" == "1" && "$IMAGE" != *:local ]]; then
  echo "Pulling $IMAGE ..."
  docker pull "$IMAGE"
fi

docker network create "$NETWORK" >/dev/null 2>&1 || true
chown_data_dir "$DATA_DIR" 1000
DATA_ABS="$(cd "$DATA_DIR" && pwd)"
CONFIG_ABS="$(cd "$(dirname "$CONFIG")" && pwd)/$(basename "$CONFIG")"

if docker inspect "$NAME" >/dev/null 2>&1; then
  echo "Removing existing container $NAME ..."
  docker rm -f "$NAME" >/dev/null
fi

echo "Starting $NAME (host port $HOST_PORT, network $NETWORK) ..."
# shellcheck disable=SC2046
docker run -d \
  --name "$NAME" \
  --restart unless-stopped \
  --network "$NETWORK" \
  $(memory_args "$MEMORY") \
  -p "${HOST_PORT}:8080" \
  -e CONFIG_PATH=/config/app.yaml \
  -e DB_PATH=/data/app.db \
  -e API_TOKEN="${API_TOKEN:-}" \
  -v "${DATA_ABS}:/data" \
  -v "${CONFIG_ABS}:/config/app.yaml:ro" \
  "$IMAGE" >/dev/null

echo "API: http://localhost:${HOST_PORT}/api/health"
echo "On network $NETWORK as hostname $NAME"
