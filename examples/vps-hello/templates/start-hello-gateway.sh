#!/usr/bin/env bash
# Start UI + HTTPS nginx. API must already be on DOCKER_NETWORK as hello-api.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=lib-env.sh
[[ -f lib-env.sh ]] && source lib-env.sh && load_dotenv .env

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi

NETWORK="${DOCKER_NETWORK:-hello-vps-edge}"
UI_NAME="${UI_NAME:-hello-ui}"
GATEWAY_NAME="${GATEWAY_NAME:-hello-gateway}"
UI_IMAGE="${UI_IMAGE:-hello-vps-ui:local}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:alpine}"
TLS_FULLCHAIN="${TLS_FULLCHAIN:-/etc/letsencrypt/live/hello.example.com/fullchain.pem}"
TLS_PRIVKEY="${TLS_PRIVKEY:-/etc/letsencrypt/live/hello.example.com/privkey.pem}"
CERTBOT_WWW="${CERTBOT_WWW:-/var/www/certbot}"
HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"
UI_MEMORY="${UI_MEMORY_LIMIT:-32m}"
GW_MEMORY="${GATEWAY_MEMORY_LIMIT:-64m}"

NGINX_CONF="$SCRIPT_DIR/gateway/nginx.conf"
CONF_D="$SCRIPT_DIR/gateway/conf.d"
if [[ ! -f "$NGINX_CONF" || ! -d "$CONF_D" ]]; then
  echo "Missing gateway/nginx.conf or gateway/conf.d — re-run install-gateway.sh" >&2
  exit 1
fi

if [[ ! -f "$TLS_FULLCHAIN" || ! -f "$TLS_PRIVKEY" ]]; then
  echo "TLS certs not found:" >&2
  echo "  $TLS_FULLCHAIN" >&2
  echo "  $TLS_PRIVKEY" >&2
  echo "Issue with certbot, or for a lab box: examples/vps-hello/scripts/gen-dev-certs.sh" >&2
  exit 1
fi

if [[ "${PULL:-1}" == "1" ]]; then
  if [[ "$UI_IMAGE" != *:local ]]; then
    echo "Pulling $UI_IMAGE ..."
    docker pull "$UI_IMAGE"
  fi
  if [[ "$NGINX_IMAGE" != *:local ]]; then
    echo "Pulling $NGINX_IMAGE ..."
    docker pull "$NGINX_IMAGE"
  fi
fi

docker network create "$NETWORK" >/dev/null 2>&1 || true
mkdir -p "$CERTBOT_WWW"

if docker inspect "$UI_NAME" >/dev/null 2>&1; then
  echo "Removing existing container $UI_NAME ..."
  docker rm -f "$UI_NAME" >/dev/null
fi
echo "Starting $UI_NAME ..."
# shellcheck disable=SC2046
docker run -d \
  --name "$UI_NAME" \
  --restart unless-stopped \
  --network "$NETWORK" \
  $(memory_args "$UI_MEMORY") \
  "$UI_IMAGE" >/dev/null

if docker inspect "$GATEWAY_NAME" >/dev/null 2>&1; then
  echo "Removing existing container $GATEWAY_NAME ..."
  docker rm -f "$GATEWAY_NAME" >/dev/null
fi
echo "Starting $GATEWAY_NAME (HTTP ${HTTP_PORT}, HTTPS ${HTTPS_PORT}) ..."
# shellcheck disable=SC2046
docker run -d \
  --name "$GATEWAY_NAME" \
  --restart unless-stopped \
  --network "$NETWORK" \
  $(memory_args "$GW_MEMORY") \
  -p "${HTTP_PORT}:80" \
  -p "${HTTPS_PORT}:443" \
  -v "$NGINX_CONF:/etc/nginx/nginx.conf:ro" \
  -v "$CONF_D:/etc/nginx/conf.d:ro" \
  -v "$TLS_FULLCHAIN:/etc/nginx/certs/fullchain.pem:ro" \
  -v "$TLS_PRIVKEY:/etc/nginx/certs/privkey.pem:ro" \
  -v "$CERTBOT_WWW:/var/www/certbot:ro" \
  "$NGINX_IMAGE" >/dev/null

echo "Gateway up on $NETWORK"
echo "  UI container: $UI_NAME"
echo "  API upstream: hello-api:8080 (start the API first)"
echo "Health: curl -fk https://127.0.0.1:${HTTPS_PORT}/api/health -H 'Host: hello.example.com'"
