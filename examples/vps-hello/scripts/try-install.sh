#!/usr/bin/env bash
# Dry-run the three VPS profiles into a temp dir (no Docker required).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
EXAMPLE="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${HELLO_TRY_DIR:-${TMPDIR:-/tmp}/hello-vps-try-$$}"
KEEP="${HELLO_TRY_KEEP:-0}"

cleanup() {
  if [[ "$KEEP" != "1" ]]; then
    rm -rf "$DEST"
  else
    echo "kept install tree: $DEST"
  fi
}
trap cleanup EXIT

mkdir -p "$DEST/api" "$DEST/nodes" "$DEST/gateway"

export PACKAGER_RAW="$ROOT"
export PACKAGECONFIG_URL="$EXAMPLE/packageconfig.yaml"
export PRODUCT_RAW="$EXAMPLE/templates"

echo "== install api =="
INSTALL_DIR="$DEST/api" bash "$ROOT/install.sh" --profile api
echo "== install nodes =="
INSTALL_DIR="$DEST/nodes" bash "$ROOT/install.sh" --profile nodes
echo "== install gateway =="
INSTALL_DIR="$DEST/gateway" bash "$ROOT/install.sh" --profile gateway

test -f "$DEST/api/.env"
test -x "$DEST/api/start-hello-api.sh"
test -x "$DEST/api/update-hello-api.sh"
test -f "$DEST/api/app.yaml"
test -f "$DEST/api/docker-compose.backend.yml"

test -f "$DEST/nodes/.env"
test -x "$DEST/nodes/start-hello-nodes.sh"
test -f "$DEST/nodes/docker-compose.hello-workers.yml"
test -f "$DEST/nodes/workers.yaml"

test -f "$DEST/gateway/.env"
test -x "$DEST/gateway/start-hello-gateway.sh"
test -f "$DEST/gateway/gateway/nginx.conf"
test -f "$DEST/gateway/gateway/conf.d/domains.conf"
grep -q "hello.example.com" "$DEST/gateway/gateway/conf.d/domains.conf"
grep -q "hello-api:8080" "$DEST/gateway/gateway/conf.d/domains.conf"
grep -q "/api/notes" "$DEST/gateway/gateway/conf.d/domains.conf"

echo "try-install OK ($DEST)"
