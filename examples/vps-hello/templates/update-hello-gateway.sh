#!/usr/bin/env bash
# Pull UI/nginx when their flags are on; recreate only containers that need a new image.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=lib-env.sh
source "$SCRIPT_DIR/lib-env.sh"
load_dotenv .env

UPDATE_UI=0
UPDATE_GATEWAY=0
role_auto_update_on UI_AUTO_UPDATE && UPDATE_UI=1
role_auto_update_on GATEWAY_AUTO_UPDATE && UPDATE_GATEWAY=1
if [[ "$UPDATE_UI$UPDATE_GATEWAY" == "00" ]]; then
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  log_update "$SCRIPT_DIR" "gateway: docker not found"
  exit 1
fi

run_gateway_update() {
  local ui_image nginx_image ui_name gw_name pull_status
  ui_image="${UI_IMAGE:-hello-vps-ui:local}"
  nginx_image="${NGINX_IMAGE:-nginx:alpine}"
  ui_name="${UI_NAME:-hello-ui}"
  gw_name="${GATEWAY_NAME:-hello-gateway}"

  if [[ "$UPDATE_UI" -eq 1 ]]; then
    if [[ "$ui_image" == *:local ]]; then
      log_update "$SCRIPT_DIR" "gateway: $ui_image — skipped pull (local tag)"
    else
      pull_status="$(pull_image_if_needed "$ui_image")"
      log_update "$SCRIPT_DIR" "gateway: $ui_image — $pull_status"
    fi
  fi
  if [[ "$UPDATE_GATEWAY" -eq 1 && "$nginx_image" != *:local ]]; then
    pull_status="$(pull_image_if_needed "$nginx_image")"
    log_update "$SCRIPT_DIR" "gateway: $nginx_image — $pull_status"
  fi

  if [[ "$UPDATE_UI" -eq 1 ]] && container_needs_image "$ui_name" "$ui_image"; then
    log_update "$SCRIPT_DIR" "gateway: updating $ui_name"
    PULL=0 "$SCRIPT_DIR/start-hello-gateway.sh"
    log_update "$SCRIPT_DIR" "gateway: $ui_name + $gw_name refreshed"
    return 0
  fi

  if [[ "$UPDATE_GATEWAY" -eq 1 ]] && container_needs_image "$gw_name" "$nginx_image"; then
    log_update "$SCRIPT_DIR" "gateway: updating $gw_name"
    PULL=0 "$SCRIPT_DIR/start-hello-gateway.sh"
    log_update "$SCRIPT_DIR" "gateway: $gw_name refreshed"
    return 0
  fi

  log_update "$SCRIPT_DIR" "gateway: already on latest images"
}

with_update_lock "$SCRIPT_DIR" "gateway" run_gateway_update
