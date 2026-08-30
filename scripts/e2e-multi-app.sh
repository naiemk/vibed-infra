#!/usr/bin/env bash
# Fast local e2e: two example apps → docker build → localhost wget|bash install →
# shared host gateway nginx includes both; HTTPS health + UI work.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELLO="$ROOT/examples/vps-hello"
SUFFIX="e2e$$"
WORK="${E2E_WORK:-/tmp/vibed-multi-app-${SUFFIX}}"
NETWORK="vps-edge-${SUFFIX}"
GW_NAME="vps-gateway-${SUFFIX}"
HTTP_PORT="${E2E_HTTP_PORT:-0}"
BASE_URL=""
export HOME="$WORK/home"
export GATEWAY_HOME="$WORK/host-gateway"
export VIBED_HOME="$WORK/vibed"
mkdir -p "$HOME" "$GATEWAY_HOME" "$VIBED_HOME" "$WORK/products" "$WORK/install" "$WORK/ui-build"

SERVER_PID=""
cleanup() {
  local code=$?
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  docker rm -f \
    "$GW_NAME" \
    hello-alpha-api hello-alpha-ui \
    hello-beta-api hello-beta-ui \
    2>/dev/null || true
  docker network rm "$NETWORK" 2>/dev/null || true
  docker volume rm "${GW_NAME}-nginx-cfg" 2>/dev/null || true
  # API data dirs are owned by container uid 1000 — wipe via docker if needed
  if [[ -d "$WORK" ]]; then
    rm -rf "$WORK" 2>/dev/null || \
      docker run --rm -v "$(dirname "$WORK"):/parent" alpine:3.20 \
        rm -rf "/parent/$(basename "$WORK")" 2>/dev/null || true
  fi
  exit "$code"
}
trap cleanup EXIT

log() { printf '+ %s\n' "$*"; }

pick_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

start_http_server() {
  local port="$1"
  python3 - "$ROOT" "$WORK" "$port" <<'PY' &
import os, sys
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from urllib.parse import unquote, urlparse

ROOT, WORK, PORT = sys.argv[1], sys.argv[2], int(sys.argv[3])
PRODUCTS = os.path.join(WORK, "products")

class Handler(SimpleHTTPRequestHandler):
    def translate_path(self, path):
        path = unquote(urlparse(path).path)
        if path.startswith("/products/"):
            rel = path[len("/products/") :]
            return os.path.normpath(os.path.join(PRODUCTS, rel))
        rel = path.lstrip("/")
        return os.path.normpath(os.path.join(ROOT, rel))

    def log_message(self, fmt, *args):
        return

ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
PY
  SERVER_PID=$!
  for _ in $(seq 1 50); do
    if wget -qO- "http://127.0.0.1:${port}/README.md" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  echo "HTTP server failed to start on $port" >&2
  return 1
}

make_product() {
  local name="$1" host="$2" title="$3"
  local dir="$WORK/products/$name"
  mkdir -p "$dir/templates"
  cat >"$dir/templates/vibed-infra-config.yml" <<EOF
name: hello-${name}
version: 1

templates:
  api: api-config.yaml
  ui: ui-config.yaml
  nodes: nodes-config.yaml

network:
  edge: vps-edge

autoUpdate:
  api: { enabled: false }
  ui: { enabled: false }
  nodes: { enabled: false }
  gateway: { enabled: false }

gateway:
  nginxImage: nginx:alpine
  sites:
    - host: ${host}
      healthPath: /api/health
      createPath: /api/notes
      tlsCertDir: ./certs
EOF
  cat >"$dir/templates/api-config.yaml" <<EOF
image: hello-${name}-api:local
port: 8080
config:
  title: ${title}
EOF
  cat >"$dir/templates/ui-config.yaml" <<EOF
image: hello-${name}-ui:local
port: 80
EOF
  cat >"$dir/templates/nodes-config.yaml" <<EOF
image: hello-vps-worker:local
config:
  intervalSec: 60
  role: heartbeat
EOF
}

package_product() {
  local name="$1"
  local dir="$WORK/products/$name"
  local dist="$dir/dist"
  local raw="${BASE_URL}/products/${name}/dist"
  python3 "$ROOT/lib/package.py" \
    --product "$dir" \
    --out "$dist" \
    --packager "$ROOT" \
    --raw-base "$raw" \
    --packager-raw "$BASE_URL"
}

build_images() {
  log "building API image once (tag alpha + beta)"
  docker build -q -t hello-alpha-api:local -t hello-beta-api:local "$HELLO/app/api" >/dev/null

  log "building UI images (tiny nginx:alpine)"
  for name_title in "alpha:Hello Alpha" "beta:Hello Beta"; do
    local name="${name_title%%:*}"
    local title="${name_title##*:}"
    local ctx="$WORK/ui-build/$name"
    mkdir -p "$ctx"
    cp "$HELLO/app/ui/Dockerfile" "$HELLO/app/ui/nginx.conf" "$ctx/"
    sed "s/Hello VPS/${title}/g" "$HELLO/app/ui/index.html" >"$ctx/index.html"
    docker build -q -t "hello-${name}-ui:local" "$ctx" >/dev/null
  done
}

patch_env() {
  local envfile="$1"
  shift
  while [[ $# -ge 2 ]]; do
    local key="$1" val="$2"
    shift 2
    if grep -q "^${key}=" "$envfile" 2>/dev/null; then
      sed -i "s|^${key}=.*|${key}=${val}|" "$envfile"
    else
      echo "${key}=${val}" >>"$envfile"
    fi
  done
}

wget_install() {
  local name="$1" profile="$2" dest="$3"
  mkdir -p "$dest"
  log "wget|bash install hello-${name} profile=${profile}"
  # Process substitution matches production: bash <(wget …/install.sh)
  INSTALL_DIR="$dest" \
    GATEWAY_HOME="$GATEWAY_HOME" \
    VIBED_HOME="$VIBED_HOME" \
    HOME="$HOME" \
    TLS_MODE=lab \
    bash <(wget -qO- "${BASE_URL}/products/${name}/dist/install-${profile}.sh")
}

curl_on_net() {
  docker run --rm --network "$NETWORK" curlimages/curl:8.5.0 "$@"
}

wait_http() {
  local url="$1" needle="$2"
  shift 2
  local i
  for i in $(seq 1 40); do
    if curl_on_net -fsS "$@" "$url" 2>/dev/null | grep -q "$needle"; then
      return 0
    fi
    sleep 0.5
  done
  echo "timeout waiting for $needle from $url" >&2
  curl_on_net -fsS "$@" "$url" >&2 || true
  return 1
}

# --- main ---
[[ "$HTTP_PORT" == "0" ]] && HTTP_PORT="$(pick_port)"
BASE_URL="http://127.0.0.1:${HTTP_PORT}"

log "work=$WORK port=$HTTP_PORT network=$NETWORK"
start_http_server "$HTTP_PORT"

make_product alpha alpha.example.com "Hello Alpha"
make_product beta beta.example.com "Hello Beta"

log "packaging both apps for localhost wget"
package_product alpha
package_product beta

# Sanity: install wrappers bake localhost URLs
grep -q "$BASE_URL" "$WORK/products/alpha/dist/install-api.sh"
grep -q "rawBase: ${BASE_URL}/products/alpha/dist" "$WORK/products/alpha/dist/packageconfig.yaml" \
  || grep -q "rawBase: '${BASE_URL}/products/alpha/dist'" "$WORK/products/alpha/dist/packageconfig.yaml" \
  || grep -Fq "${BASE_URL}/products/alpha/dist" "$WORK/products/alpha/dist/packageconfig.yaml"

build_images

# Install via wget|bash (api → ui → gateway) for both apps
for name in alpha beta; do
  wget_install "$name" api "$WORK/install/$name/api"
  wget_install "$name" ui "$WORK/install/$name/ui"
  wget_install "$name" gateway "$WORK/install/$name/gateway"
done

# Shared host edge + unique gateway name / high ports (no root)
patch_env "$GATEWAY_HOME/.env" \
  DOCKER_NETWORK "$NETWORK" \
  GATEWAY_NAME "$GW_NAME" \
  HTTP_PORT "18088" \
  HTTPS_PORT "18443" \
  TLS_MODE "lab" \
  PULL "0"

# Lab certs already issued by setup-tls during gateway install (both app SANs after beta)
test -f "$GATEWAY_HOME/certs/fullchain.pem"
test -f "$GATEWAY_HOME/.vibed-tls-state"
grep -q 'alpha.example.com' "$GATEWAY_HOME/.vibed-tls-state"
grep -q 'beta.example.com' "$GATEWAY_HOME/.vibed-tls-state"

api_port_alpha=19081
api_port_beta=19082
for name in alpha beta; do
  if [[ "$name" == alpha ]]; then local_port=$api_port_alpha; else local_port=$api_port_beta; fi
  patch_env "$WORK/install/$name/api/.env" \
    DOCKER_NETWORK "$NETWORK" \
    DOCKER_NAME "hello-${name}-api" \
    HOST_PORT "$local_port" \
    API_TOKEN "token-${name}" \
    PULL "0" \
    PERSIST_LOG_DIR "$WORK/persist/$name"
  patch_env "$WORK/install/$name/ui/.env" \
    DOCKER_NETWORK "$NETWORK" \
    UI_NAME "hello-${name}-ui" \
    PULL "0"
done

# Host gateway inclusive layout
test -f "$GATEWAY_HOME/.vibed-host-gateway"
test -f "$GATEWAY_HOME/apps/hello-alpha/sites.conf"
test -f "$GATEWAY_HOME/apps/hello-beta/sites.conf"
grep -q 'include /etc/nginx/apps/\*/sites.conf' "$GATEWAY_HOME/gateway/nginx.conf"
grep -q 'alpha.example.com' "$GATEWAY_HOME/apps/hello-alpha/sites.conf"
grep -q 'beta.example.com' "$GATEWAY_HOME/apps/hello-beta/sites.conf"
grep -q 'hello-alpha-api' "$GATEWAY_HOME/apps/hello-alpha/sites.conf"
grep -q 'hello-beta-api' "$GATEWAY_HOME/apps/hello-beta/sites.conf"
log "host gateway sites inclusive OK"

log "starting containers"
(cd "$WORK/install/alpha/api" && ./start-api.sh)
(cd "$WORK/install/beta/api" && ./start-api.sh)
(cd "$WORK/install/alpha/ui" && ./start-ui.sh)
(cd "$WORK/install/beta/ui" && ./start-ui.sh)
wait_http "http://hello-alpha-api:8080/api/health" '"ok"'
wait_http "http://hello-beta-api:8080/api/health" '"ok"'

(cd "$WORK/install/alpha/gateway" && ./start-gateway.sh)
# Ensure gateway is on the isolated test network (start already joins DOCKER_NETWORK)
docker network connect "$NETWORK" "$GW_NAME" 2>/dev/null || true

# Nginx inside container must carry both app sites
docker exec "$GW_NAME" sh -c 'test -f /etc/nginx/apps/hello-alpha/sites.conf'
docker exec "$GW_NAME" sh -c 'test -f /etc/nginx/apps/hello-beta/sites.conf'
docker exec "$GW_NAME" sh -c 'grep -q "include /etc/nginx/apps" /etc/nginx/nginx.conf'
docker exec "$GW_NAME" nginx -t 2>/dev/null | grep -q successful \
  || docker exec "$GW_NAME" nginx -t

log "probing both hosts via gateway"
wait_http "https://${GW_NAME}/api/health" '"ok"' -k -H "Host: alpha.example.com"
wait_http "https://${GW_NAME}/api/health" '"ok"' -k -H "Host: beta.example.com"
wait_http "https://${GW_NAME}/" "Hello Alpha" -k -H "Host: alpha.example.com"
wait_http "https://${GW_NAME}/" "Hello Beta" -k -H "Host: beta.example.com"

# API create through gateway (alpha) — retry; shared docker SNAT can trip create rate limit
body=""
for _ in $(seq 1 8); do
  body="$(curl_on_net -ksS -w '\n%{http_code}' -X POST "https://${GW_NAME}/api/notes" \
    -H "Host: alpha.example.com" \
    -H "Authorization: Bearer token-alpha" \
    -H "Content-Type: application/json" \
    --data-binary '{"author":"e2e","body":"multi-app-ok"}' 2>/dev/null || true)"
  if echo "$body" | grep -q '"id"'; then
    break
  fi
  sleep 1
done
echo "$body" | grep -q '"id"' || {
  echo "POST via gateway failed: $body" >&2
  docker logs "$GW_NAME" 2>&1 | tail -40 >&2 || true
  exit 1
}
wait_http "https://${GW_NAME}/api/notes" 'multi-app-ok' -k -H "Host: alpha.example.com"

# HTTP→HTTPS redirect
code="$(curl_on_net -sS -o /dev/null -w '%{http_code}' "http://${GW_NAME}/" -H "Host: beta.example.com" || true)"
[[ "$code" == "301" || "$code" == "308" ]] || { echo "expected redirect, got $code" >&2; exit 1; }

echo "e2e-multi-app OK (alpha+beta on shared host gateway)"
