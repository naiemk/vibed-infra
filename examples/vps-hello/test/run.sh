#!/usr/bin/env bash
# Fake VPS: install dist artifacts and prove profile api|ui|nodes.
set -euo pipefail

PROFILE="${PROFILE:-api}"
SUFFIX="${TEST_SUFFIX:-${PROFILE}}"
NETWORK="vps-edge-${SUFFIX}"
API_NAME="hello-vps-api-${SUFFIX}"
UI_NAME="hello-vps-ui-${SUFFIX}"
GW_NAME="vps-gateway-${SUFFIX}"
WORKER_NAME="hello-vps-worker-${SUFFIX}"
HOST="hello.example.com"
API_TOKEN="${API_TOKEN:-test-secret-token}"
DIST="${DIST_DIR:-/opt/dist}"
PACKAGER="${PACKAGER_ROOT:-/opt/vibed-infra}"
BASE="${TEST_BASE:-/tmp/hello-${SUFFIX}}"
export GATEWAY_HOME="${TEST_GATEWAY_HOME:-$BASE/host-gateway}"
export VIBED_HOME="${TEST_VIBED_HOME:-$BASE/vibed}"
export HOME="${TEST_HOME:-$BASE/home}"
mkdir -p "$HOME" "$GATEWAY_HOME" "$VIBED_HOME"

cleanup() {
  docker rm -f "$API_NAME" "$UI_NAME" "$GW_NAME" "$WORKER_NAME" \
    "${API_NAME}-persist-ship" "${WORKER_NAME}-persist-ship" 2>/dev/null || true
  docker network rm "$NETWORK" 2>/dev/null || true
  docker volume rm \
    "${API_NAME}-data" "${API_NAME}-persist" \
    "${WORKER_NAME}-logs" "${WORKER_NAME}-persist" \
    "${GW_NAME}-nginx-cfg" \
    2>/dev/null || true
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
    GATEWAY_HOME="$GATEWAY_HOME" VIBED_HOME="$VIBED_HOME" \
    bash "$DIST/install-${prof}.sh"
}

start_dir() {
  local dir="$1" script="$2"
  (cd "$dir" && ./"$script")
}

wait_http() {
  local url="$1" needle="$2"
  shift 2
  local i
  for i in $(seq 1 40); do
    if curl_on_net -fsS "$@" "$url" 2>/dev/null | grep -q "$needle"; then
      return 0
    fi
    sleep 1
  done
  echo "timeout waiting for $needle from $url" >&2
  curl_on_net -fsS "$@" "$url" >&2 || true
  return 1
}

case "$PROFILE" in
  api)
    install_profile api "$BASE/api"
    patch_env "$BASE/api/.env" \
      DOCKER_NETWORK "$NETWORK" \
      DOCKER_NAME "$API_NAME" \
      API_TOKEN "$API_TOKEN" \
      HOST_PORT "18080"
    sed -i '/^DATA_DIR=/d;/^PERSIST_LOG_DIR=/d' "$BASE/api/.env" 2>/dev/null || true
    start_dir "$BASE/api" start-api.sh
    wait_http "http://${API_NAME}:8080/api/health" '"ok"'
    docker volume inspect "${API_NAME}-data" >/dev/null
    docker volume inspect "${API_NAME}-persist" >/dev/null
    docker inspect "${API_NAME}-persist-ship" >/dev/null
    mounts="$(docker inspect "${API_NAME}-persist-ship" --format '{{range .Mounts}}{{.Source}} {{end}}')"
    if printf '%s' " $mounts " | grep -Fq 'docker.sock'; then
      echo "sidecar must not mount docker.sock" >&2
      exit 1
    fi
    # Avoid curl -f: 201 Created is success but some clients are picky with pipelines
    body="$(curl_on_net -sS -w '\n%{http_code}' -X POST "http://${API_NAME}:8080/api/notes" \
      -H "Authorization: Bearer ${API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data-binary '{"author":"test","body":"from-api-job"}' || true)"
    echo "$body" | grep -q '"id"' || { echo "POST /api/notes failed: $body" >&2; exit 1; }
    wait_http "http://${API_NAME}:8080/api/notes" 'from-api-job'
    # Survive recreate
    start_dir "$BASE/api" start-api.sh
    wait_http "http://${API_NAME}:8080/api/notes" 'from-api-job'
    test -x "$VIBED_HOME/monitor-vibed.sh"
    list_out="$("$VIBED_HOME/monitor-vibed.sh" --list)"
    [[ "$list_out" == *"$API_NAME"* ]] || { echo "monitor --list missing $API_NAME: $list_out" >&2; exit 1; }
    sum_out="$("$VIBED_HOME/monitor-vibed.sh" --summary "$API_NAME")"
    [[ "$sum_out" == *"${API_NAME}-persist"* ]] || { echo "monitor --summary missing persist vol: $sum_out" >&2; exit 1; }
    echo "dist-e2e api OK"
    ;;
  nodes)
    install_profile api "$BASE/api"
    install_profile nodes "$BASE/nodes"
    patch_env "$BASE/api/.env" \
      DOCKER_NETWORK "$NETWORK" \
      DOCKER_NAME "$API_NAME" \
      API_TOKEN "$API_TOKEN" \
      HOST_PORT "18081"
    patch_env "$BASE/nodes/.env" \
      DOCKER_NETWORK "$NETWORK" \
      WORKER_CONTAINER_NAME "$WORKER_NAME" \
      API_URL "http://${API_NAME}:8080" \
      API_TOKEN "$API_TOKEN" \
      INTERVAL_SEC "5"
    start_dir "$BASE/api" start-api.sh
    wait_http "http://${API_NAME}:8080/api/health" '"ok"'
    start_dir "$BASE/nodes" start-nodes.sh
    wait_http "http://${API_NAME}:8080/api/notes" 'heartbeat'
    echo "dist-e2e nodes OK"
    ;;
  ui)
    install_profile api "$BASE/api"
    install_profile ui "$BASE/ui"
    install_profile gateway "$BASE/gateway"
    # Host gateway must use our isolated network + container name
    patch_env "$GATEWAY_HOME/.env" \
      DOCKER_NETWORK "$NETWORK" \
      GATEWAY_NAME "$GW_NAME"
    patch_env "$BASE/api/.env" \
      DOCKER_NETWORK "$NETWORK" \
      DOCKER_NAME "$API_NAME" \
      API_TOKEN "$API_TOKEN" \
      HOST_PORT "18082"
    patch_env "$BASE/ui/.env" \
      DOCKER_NETWORK "$NETWORK" \
      UI_NAME "$UI_NAME"
    CERT_DIR="$GATEWAY_HOME/certs"
    APP_HOST="$HOST" bash "$DIST/gen-dev-certs.sh" "$CERT_DIR"
    patch_env "$GATEWAY_HOME/.env" \
      TLS_FULLCHAIN "$CERT_DIR/fullchain.pem" \
      TLS_PRIVKEY "$CERT_DIR/privkey.pem"
    # Point generated sites at test container names
    if [[ -f "$GATEWAY_HOME/apps/hello-vps/sites.conf" ]]; then
      sed -i "s/hello-vps-api:/${API_NAME}:/g" "$GATEWAY_HOME/apps/hello-vps/sites.conf"
      sed -i "s/hello-vps-ui:/${UI_NAME}:/g" "$GATEWAY_HOME/apps/hello-vps/sites.conf"
    fi
    test -f "$GATEWAY_HOME/.vibed-host-gateway"
    test -f "$GATEWAY_HOME/apps/hello-vps/sites.conf"
    start_dir "$BASE/api" start-api.sh
    start_dir "$BASE/ui" start-ui.sh
    wait_http "http://${API_NAME}:8080/api/health" '"ok"'
    start_dir "$BASE/gateway" start-gateway.sh
    docker network connect "$NETWORK" "$GW_NAME" 2>/dev/null || true
    found=0
    for _ in $(seq 1 40); do
      if curl_on_net -kfsS "https://${GW_NAME}/api/health" -H "Host: ${HOST}" 2>/dev/null | grep -q '"ok"'; then
        found=1
        break
      fi
      sleep 1
    done
    [[ "$found" -eq 1 ]] || {
      echo "gateway health timeout" >&2
      docker logs "$GW_NAME" 2>&1 | tail -30 >&2 || true
      exit 1
    }
    html=""
    for _ in $(seq 1 20); do
      html="$(curl_on_net -kfsS "https://${GW_NAME}/" -H "Host: ${HOST}" 2>/dev/null || true)"
      if echo "$html" | grep -q "Hello VPS"; then
        break
      fi
      sleep 1
    done
    echo "$html" | grep -q "Hello VPS" || { echo "UI HTML missing Hello VPS: $html" >&2; exit 1; }
    code="$(curl_on_net -sS -o /dev/null -w '%{http_code}' "http://${GW_NAME}/" -H "Host: ${HOST}" || true)"
    [[ "$code" == "301" ]] || [[ "$code" == "308" ]] || { echo "expected HTTP redirect, got $code" >&2; exit 1; }
    echo "dist-e2e ui OK"
    ;;
  *)
    echo "unknown PROFILE=$PROFILE" >&2
    exit 1
    ;;
esac
