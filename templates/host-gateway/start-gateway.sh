#!/usr/bin/env bash
# Start (or recreate) the shared host nginx gateway. Mounts apps/*/sites.conf.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=lib-env.sh
[[ -f lib-env.sh ]] && source lib-env.sh && load_dotenv .env

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi

NETWORK="${DOCKER_NETWORK:-vps-edge}"
GATEWAY_NAME="${GATEWAY_NAME:-vps-gateway}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:alpine}"
TLS_FULLCHAIN="${TLS_FULLCHAIN:-./certs/fullchain.pem}"
TLS_PRIVKEY="${TLS_PRIVKEY:-./certs/privkey.pem}"
CERTBOT_WWW="${CERTBOT_WWW:-./certbot-www}"
HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${HTTPS_PORT:-443}"
GW_MEMORY="${GATEWAY_MEMORY_LIMIT:-64m}"

NGINX_CONF="$SCRIPT_DIR/gateway/nginx.conf"
CONF_D="$SCRIPT_DIR/gateway/conf.d"
APPS_DIR="$SCRIPT_DIR/apps"
if [[ ! -f "$NGINX_CONF" || ! -d "$CONF_D" ]]; then
  echo "Missing gateway/nginx.conf or gateway/conf.d — re-run host gateway bootstrap" >&2
  exit 1
fi

if [[ ! -f "$TLS_FULLCHAIN" || ! -f "$TLS_PRIVKEY" ]]; then
  echo "TLS certs not found:" >&2
  echo "  $TLS_FULLCHAIN" >&2
  echo "  $TLS_PRIVKEY" >&2
  echo "Run ./setup-tls.sh (lab or letsencrypt) to create ./certs PEMs." >&2
  exit 1
fi

if [[ "${PULL:-1}" == "1" && "$NGINX_IMAGE" != *:local ]]; then
  echo "Pulling $NGINX_IMAGE ..."
  docker pull "$NGINX_IMAGE"
fi

docker network create "$NETWORK" >/dev/null 2>&1 || true
mkdir -p "$CERTBOT_WWW" "$APPS_DIR"
# Absolute path for live ACME webroot bind mount
CERTBOT_ABS="$CERTBOT_WWW"
[[ "$CERTBOT_ABS" != /* ]] && CERTBOT_ABS="${SCRIPT_DIR}/${CERTBOT_ABS#./}"
mkdir -p "$CERTBOT_ABS"

if docker inspect "$GATEWAY_NAME" >/dev/null 2>&1; then
  echo "Removing existing container $GATEWAY_NAME ..."
  docker rm -f "$GATEWAY_NAME" >/dev/null
fi

CONF_VOL="${GATEWAY_NAME}-nginx-cfg"
docker volume rm "$CONF_VOL" 2>/dev/null || true
docker volume create "$CONF_VOL" >/dev/null

STAGE="$(mktemp -d)"
cleanup_stage() { rm -rf "$STAGE"; }
trap cleanup_stage EXIT

mkdir -p "$STAGE/conf.d" "$STAGE/certs" "$STAGE/apps"
cp "$NGINX_CONF" "$STAGE/nginx.conf"
cp -r "$CONF_D/." "$STAGE/conf.d/"
cp "$TLS_FULLCHAIN" "$STAGE/certs/fullchain.pem"
cp "$TLS_PRIVKEY" "$STAGE/certs/privkey.pem"
if [[ -d "$APPS_DIR" ]]; then
  # Copy only apps that have sites.conf
  for app in "$APPS_DIR"/*/; do
    [[ -d "$app" ]] || continue
    if [[ -f "${app}sites.conf" ]]; then
      b="$(basename "$app")"
      mkdir -p "$STAGE/apps/$b"
      cp "${app}sites.conf" "$STAGE/apps/$b/sites.conf"
      [[ -f "${app}meta.json" ]] && cp "${app}meta.json" "$STAGE/apps/$b/meta.json"
    fi
  done
fi
tar -C "$STAGE" -cf - . | docker run --rm -i -v "${CONF_VOL}:/cfg" alpine tar -xf - -C /cfg

echo "Starting $GATEWAY_NAME (HTTP ${HTTP_PORT}, HTTPS ${HTTPS_PORT}) ..."
# shellcheck disable=SC2046
docker run -d \
  --name "$GATEWAY_NAME" \
  --restart unless-stopped \
  --network "$NETWORK" \
  --add-host=host.docker.internal:host-gateway \
  --label "vibed.managed=1" \
  --label "vibed.role=gateway" \
  $(memory_args "$GW_MEMORY" 2>/dev/null || true) \
  -p "${HTTP_PORT}:80" \
  -p "${HTTPS_PORT}:443" \
  -v "${CONF_VOL}:/gateway-cfg:ro" \
  -v "${CERTBOT_ABS}:/var/www/certbot" \
  "$NGINX_IMAGE" \
  sh -c 'mkdir -p /etc/nginx/certs /etc/nginx/conf.d /etc/nginx/apps /var/www/certbot && \
    cp /gateway-cfg/nginx.conf /etc/nginx/nginx.conf && \
    cp /gateway-cfg/conf.d/*.conf /etc/nginx/conf.d/ && \
    if [ -d /gateway-cfg/apps ]; then cp -r /gateway-cfg/apps/. /etc/nginx/apps/; fi && \
    cp /gateway-cfg/certs/fullchain.pem /etc/nginx/certs/fullchain.pem && \
    cp /gateway-cfg/certs/privkey.pem /etc/nginx/certs/privkey.pem && \
    exec nginx -g "daemon off;"' >/dev/null

trap - EXIT
cleanup_stage

echo "Host gateway $GATEWAY_NAME up on network $NETWORK (apps under $APPS_DIR)"
