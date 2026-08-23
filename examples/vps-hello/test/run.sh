#!/usr/bin/env bash
# Fake VPS: install dist artifacts and prove profile api|ui|nodes.
set -euo pipefail

PROFILE="${PROFILE:-api}"
SUFFIX="${TEST_SUFFIX:-${PROFILE}}"
NETWORK="hello-vps-edge-${SUFFIX}"
API_NAME="hello-vps-api-${SUFFIX}"
UI_NAME="hello-vps-ui-${SUFFIX}"
GW_NAME="hello-vps-gateway-${SUFFIX}"
WORKER_NAME="hello-vps-worker-${SUFFIX}"
HOST="hello.example.com"
API_TOKEN="${API_TOKEN:-test-secret-token}"
DIST="${DIST_DIR:-/opt/dist}"
PACKAGER="${PACKAGER_ROOT:-/opt/vibed-infra}"
BASE="${TEST_BASE:-/tmp/hello-${SUFFIX}}"

cleanup() {
  docker rm -f "$API_NAME" "$UI_NAME" "$GW_NAME" "$WORKER_NAME" 2>/dev/null || true
  docker network rm "$NETWORK" 2>/dev/null || true
}
trap cleanup EXIT

curl_on_net() {
  docker run --rm --network "$NETWORK" curlimages/curl:8.5.0 "$@"
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

install_profile() {
  local prof="$1" dest="$2"
  mkdir -p "$dest"
  PACKAGER_RAW="$PACKAGER" PRODUCT_RAW="$DIST" INSTALL_DIR="$dest" \
    bash "$DIST/install-${prof}.sh"
}

start_dir() {
  local dir="$1" script="$2"
  (cd "$dir" && ./"$script")
}

case "$PROFILE" in
  api)
    install_profile api "$BASE/api"
    patch_env "$BASE/api/.env" \
      DOCKER_NETWORK "$NETWORK" \
      DOCKER_NAME "$API_NAME" \
      API_TOKEN "$API_TOKEN"
    start_dir "$BASE/api" start-api.sh
    for _ in $(seq 1 30); do
      if curl_on_net -fsS "http://${API_NAME}:8080/api/health" | grep -q '"ok"'; then
        break
      fi
      sleep 1
    done
    curl_on_net -fsS "http://${API_NAME}:8080/api/health" | grep -q '"ok"'
    curl_on_net -fsS -X POST "http://${API_NAME}:8080/api/notes" \
      -H "Authorization: Bearer ${API_TOKEN}" \
      -H "Content-Type: application/json" \
      -d '{"author":"test","body":"from-api-job"}' | grep -q '"id"'
    curl_on_net -fsS "http://${API_NAME}:8080/api/notes" | grep -q from-api-job
    echo "dist-e2e api OK"
    ;;
  nodes)
    install_profile api "$BASE/api"
    install_profile nodes "$BASE/nodes"
    patch_env "$BASE/api/.env" \
      DOCKER_NETWORK "$NETWORK" \
      DOCKER_NAME "$API_NAME" \
      API_TOKEN "$API_TOKEN"
    patch_env "$BASE/nodes/.env" \
      DOCKER_NETWORK "$NETWORK" \
      WORKER_CONTAINER_NAME "$WORKER_NAME" \
      API_URL "http://${API_NAME}:8080" \
      API_TOKEN "$API_TOKEN" \
      INTERVAL_SEC "5"
    start_dir "$BASE/api" start-api.sh
    for _ in $(seq 1 30); do
      if curl_on_net -fsS "http://${API_NAME}:8080/api/health" 2>/dev/null | grep -q '"ok"'; then
        break
      fi
      sleep 1
    done
    curl_on_net -fsS "http://${API_NAME}:8080/api/health" | grep -q '"ok"'
    start_dir "$BASE/nodes" start-nodes.sh
    found=0
    for _ in $(seq 1 30); do
      if curl_on_net -fsS "http://${API_NAME}:8080/api/notes" | grep -q heartbeat; then
        found=1
        break
      fi
      sleep 2
    done
    [[ "$found" -eq 1 ]] || { echo "worker heartbeat not observed" >&2; exit 1; }
    echo "dist-e2e nodes OK"
    ;;
  ui)
    install_profile api "$BASE/api"
    install_profile ui "$BASE/ui"
    install_profile gateway "$BASE/gateway"
    patch_env "$BASE/api/.env" \
      DOCKER_NETWORK "$NETWORK" \
      DOCKER_NAME "$API_NAME" \
      API_TOKEN "$API_TOKEN"
    patch_env "$BASE/ui/.env" \
      DOCKER_NETWORK "$NETWORK" \
      UI_NAME "$UI_NAME"
    CERT_DIR="$BASE/gateway/certs"
    APP_HOST="$HOST" bash "$DIST/gen-dev-certs.sh" "$CERT_DIR"
    patch_env "$BASE/gateway/.env" \
      DOCKER_NETWORK "$NETWORK" \
      GATEWAY_NAME "$GW_NAME" \
      TLS_FULLCHAIN "$CERT_DIR/fullchain.pem" \
      TLS_PRIVKEY "$CERT_DIR/privkey.pem"
    if [[ -f "$BASE/gateway/gateway/conf.d/domains.conf" ]]; then
      sed -i "s/hello-vps-api:/${API_NAME}:/g" "$BASE/gateway/gateway/conf.d/domains.conf"
      sed -i "s/hello-vps-ui:/${UI_NAME}:/g" "$BASE/gateway/gateway/conf.d/domains.conf"
    fi
    start_dir "$BASE/api" start-api.sh
    start_dir "$BASE/ui" start-ui.sh
    for _ in $(seq 1 30); do
      if curl_on_net -fsS "http://${API_NAME}:8080/api/health" 2>/dev/null | grep -q '"ok"'; then
        break
      fi
      sleep 1
    done
    start_dir "$BASE/gateway" start-gateway.sh
    for _ in $(seq 1 30); do
      if curl_on_net -kfsS "https://${GW_NAME}/api/health" -H "Host: ${HOST}" | grep -q '"ok"'; then
        break
      fi
      sleep 1
    done
    curl_on_net -kfsS "https://${GW_NAME}/api/health" -H "Host: ${HOST}" | grep -q '"ok"'
    curl_on_net -kfsS "https://${GW_NAME}/" -H "Host: ${HOST}" | grep -q "Hello VPS"
    code="$(curl_on_net -sS -o /dev/null -w '%{http_code}' "http://${GW_NAME}/" -H "Host: ${HOST}" || true)"
    [[ "$code" == "301" ]] || [[ "$code" == "308" ]] || { echo "expected HTTP redirect, got $code" >&2; exit 1; }
    echo "dist-e2e ui OK"
    ;;
  *)
    echo "unknown PROFILE=$PROFILE" >&2
    exit 1
    ;;
esac
