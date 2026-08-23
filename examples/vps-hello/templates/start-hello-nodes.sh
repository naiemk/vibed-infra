#!/usr/bin/env bash
# Start hello-vps workers (compose). API should already be on DOCKER_NETWORK.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=lib-env.sh
[[ -f lib-env.sh ]] && source lib-env.sh && load_dotenv .env

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi

COMPOSE="docker-compose.hello-workers.yml"
if [[ ! -f "$COMPOSE" ]]; then
  echo "Missing $COMPOSE — run install-nodes.sh first." >&2
  exit 1
fi

IMAGE="${WORKER_IMAGE:-hello-vps-worker:local}"
NETWORK="${DOCKER_NETWORK:-hello-vps-edge}"
mkdir -p logs
docker network create "$NETWORK" >/dev/null 2>&1 || true

if [[ "${PULL:-1}" == "1" && "$IMAGE" != *:local ]]; then
  echo "Pulling $IMAGE ..."
  docker pull "$IMAGE"
fi

docker compose -f "$COMPOSE" up -d --force-recreate
echo "Workers up on network $NETWORK (API_URL=${API_URL:-http://hello-api:8080})"
