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
CONFIG_ABS="$(cd "$(dirname "$CONFIG")" && pwd)/$(basename "$CONFIG")"

vibed_resolve_data_storage "$NAME" "api"
vibed_resolve_persist_storage "$NAME" "api"

DATA_ARGS=()
LABEL_ARGS=(
  --label "vibed.managed=1"
  --label "vibed.role=api"
)
if [[ "$VIBED_DATA_MODE" == "bind" ]]; then
  mkdir -p "$VIBED_DATA_BIND_PATH"
  chown_data_dir "$VIBED_DATA_BIND_PATH" 1000
  DATA_ABS="$(cd "$VIBED_DATA_BIND_PATH" && pwd)"
  DATA_ARGS=(-v "${DATA_ABS}:/data")
else
  DATA_ARGS=(-v "${VIBED_DATA_VOLUME}:/data")
  LABEL_ARGS+=(--label "vibed.data-volume=${VIBED_DATA_VOLUME}")
fi

PERSIST_ARGS=()
if [[ "$VIBED_PERSIST_MODE" == "bind" ]]; then
  mkdir -p "$VIBED_PERSIST_BIND_PATH"
  PERSIST_ABS="$(cd "$VIBED_PERSIST_BIND_PATH" && pwd)"
  PERSIST_ARGS=(-e "PERSIST_LOG_DIR=/persist-logs" -v "${PERSIST_ABS}:/persist-logs")
elif [[ "$VIBED_PERSIST_MODE" == "volume" ]]; then
  PERSIST_ARGS=(-e "PERSIST_LOG_DIR=/persist-logs" -v "${VIBED_PERSIST_VOLUME}:/persist-logs")
  LABEL_ARGS+=(--label "vibed.persist-volume=${VIBED_PERSIST_VOLUME}")
fi

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
  "${LABEL_ARGS[@]}" \
  -p "${HOST_PORT}:8080" \
  -e CONFIG_PATH=/config/app.yaml \
  -e DB_PATH=/data/app.db \
  -e API_TOKEN="${API_TOKEN:-}" \
  "${DATA_ARGS[@]}" \
  -v "${CONFIG_ABS}:/config/app.yaml:ro" \
  "${PERSIST_ARGS[@]}" \
  "$IMAGE" >/dev/null

# App first, then sidecar (so empty persist volume is initialized by the app image).
if [[ "$VIBED_PERSIST_MODE" == "volume" ]]; then
  if [[ -f "$SCRIPT_DIR/start-persist-sidecar.sh" ]]; then
    bash "$SCRIPT_DIR/start-persist-sidecar.sh" "$NAME" "$VIBED_PERSIST_VOLUME" || true
  elif [[ -f "${PACKAGER_RAW:-}/templates/persist-logs/start-persist-sidecar.sh" ]]; then
    bash "${PACKAGER_RAW}/templates/persist-logs/start-persist-sidecar.sh" "$NAME" "$VIBED_PERSIST_VOLUME" || true
  fi
fi

echo "API: http://localhost:${HOST_PORT}/api/health"
echo "On network $NETWORK as hostname $NAME"
if [[ "$VIBED_DATA_MODE" == "volume" ]]; then
  echo "Data volume: $VIBED_DATA_VOLUME"
fi
if [[ "$VIBED_PERSIST_MODE" == "volume" ]]; then
  echo "Persist volume: $VIBED_PERSIST_VOLUME"
fi
