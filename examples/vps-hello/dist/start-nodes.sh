#!/usr/bin/env bash
# Generic worker start via compose — API must already be on DOCKER_NETWORK.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=lib-env.sh
[[ -f lib-env.sh ]] && source lib-env.sh && load_dotenv .env

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi

COMPOSE="${WORKER_COMPOSE:-docker-compose.workers.yml}"
if [[ ! -f "$COMPOSE" ]]; then
  echo "Missing $COMPOSE — run install-nodes.sh first." >&2
  exit 1
fi

IMAGE="${WORKER_IMAGE:-ghcr.io/example/worker:main}"
NAME="${WORKER_CONTAINER_NAME:-app-worker}"
NETWORK="${DOCKER_NETWORK:-app-edge}"

vibed_resolve_logs_storage "$NAME" "nodes"
vibed_resolve_persist_storage "$NAME" "nodes"

export WORKER_LOG_VOLUME="${VIBED_LOGS_VOLUME}"
export PERSIST_LOG_VOLUME="${VIBED_PERSIST_VOLUME:-${NAME}-persist}"

GEN=""
cleanup_gen() {
  [[ -n "$GEN" && -f "$GEN" ]] && rm -f "$GEN"
}
trap cleanup_gen EXIT

if [[ "$VIBED_LOGS_MODE" == "volume" && "$VIBED_PERSIST_MODE" == "volume" ]]; then
  vibed_ensure_volume "$WORKER_LOG_VOLUME" "nodes" "$NAME" "vibed.kind=logs"
  vibed_ensure_volume "$PERSIST_LOG_VOLUME" "nodes" "$NAME" "vibed.kind=persist"
  COMPOSE_ARGS=(-f "$COMPOSE")
  trap - EXIT
else
  GEN="$(mktemp "${SCRIPT_DIR}/.compose-gen.XXXXXX.yml")"
  CONFIG_FILE_REL="${CONFIG_FILE:-./workers.yaml}"
  {
    echo "networks:"
    echo "  edge:"
    echo "    external: true"
    echo "    name: ${NETWORK}"
    echo "services:"
    echo "  worker:"
    echo "    image: ${IMAGE}"
    echo "    container_name: ${NAME}"
    echo "    restart: unless-stopped"
    echo "    mem_limit: ${WORKER_MEMORY_LIMIT:-192m}"
    echo "    env_file: .env"
    echo "    labels:"
    echo "      vibed.managed: \"1\""
    echo "      vibed.role: nodes"
    [[ "$VIBED_LOGS_MODE" == "volume" ]] && echo "      vibed.logs-volume: ${WORKER_LOG_VOLUME}"
    [[ "$VIBED_PERSIST_MODE" == "volume" ]] && echo "      vibed.persist-volume: ${PERSIST_LOG_VOLUME}"
    echo "    environment:"
    echo "      WORKER_CONFIG: /config/workers.yaml"
    echo "      API_URL: ${API_URL:-http://app-api:8080}"
    echo "      INTERVAL_SEC: ${INTERVAL_SEC:-60}"
    if [[ "$VIBED_PERSIST_MODE" == "off" ]]; then
      echo "      PERSIST_LOG_DIR: \"\""
    else
      echo "      PERSIST_LOG_DIR: /persist-logs"
    fi
    echo "    volumes:"
    if [[ "$VIBED_LOGS_MODE" == "bind" ]]; then
      mkdir -p "$VIBED_LOGS_BIND_PATH"
      echo "      - $(cd "$VIBED_LOGS_BIND_PATH" && pwd):/data/logs"
    else
      vibed_ensure_volume "$WORKER_LOG_VOLUME" "nodes" "$NAME" "vibed.kind=logs"
      echo "      - ${WORKER_LOG_VOLUME}:/data/logs"
    fi
    if [[ "$VIBED_PERSIST_MODE" == "bind" ]]; then
      mkdir -p "$VIBED_PERSIST_BIND_PATH"
      echo "      - $(cd "$VIBED_PERSIST_BIND_PATH" && pwd):/persist-logs"
    elif [[ "$VIBED_PERSIST_MODE" == "volume" ]]; then
      vibed_ensure_volume "$PERSIST_LOG_VOLUME" "nodes" "$NAME" "vibed.kind=persist"
      echo "      - ${PERSIST_LOG_VOLUME}:/persist-logs"
    fi
    echo "      - ${CONFIG_FILE_REL}:/config/workers.yaml:ro"
    echo "    extra_hosts:"
    echo "      - \"host.docker.internal:host-gateway\""
    echo "    networks:"
    echo "      - edge"
  } >"$GEN"
  COMPOSE_ARGS=(-f "$GEN")
fi

docker network create "$NETWORK" >/dev/null 2>&1 || true

if [[ "${PULL:-1}" == "1" && "$IMAGE" != *:local ]]; then
  echo "Pulling $IMAGE ..."
  docker pull "$IMAGE"
fi

docker compose "${COMPOSE_ARGS[@]}" up -d --force-recreate

if [[ "$VIBED_PERSIST_MODE" == "volume" ]]; then
  if [[ -f "$SCRIPT_DIR/start-persist-sidecar.sh" ]]; then
    bash "$SCRIPT_DIR/start-persist-sidecar.sh" "$NAME" "$PERSIST_LOG_VOLUME" || true
  fi
fi

echo "Workers up on network $NETWORK (API_URL=${API_URL:-http://app-api:8080})"
if [[ "$VIBED_LOGS_MODE" == "volume" ]]; then
  echo "Logs volume: $WORKER_LOG_VOLUME"
fi
if [[ "$VIBED_PERSIST_MODE" == "volume" ]]; then
  echo "Persist volume: $PERSIST_LOG_VOLUME"
fi
