#!/usr/bin/env bash
# Digest-gated pull + recreate when API_AUTO_UPDATE is on.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=lib-env.sh
source "$SCRIPT_DIR/lib-env.sh"
load_dotenv .env

if ! role_auto_update_on API_AUTO_UPDATE; then
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  log_update "$SCRIPT_DIR" "api: docker not found"
  exit 1
fi

run_api_update() {
  local image name stop_timeout pull_status
  image="${BACKEND_IMAGE:-hello-vps-api:local}"
  name="${DOCKER_NAME:-hello-api}"
  stop_timeout="${API_STOP_TIMEOUT:-${STOP_TIMEOUT:-60}}"

  if [[ "$image" == *:local ]]; then
    log_update "$SCRIPT_DIR" "api: $image — skipped pull (local tag)"
  else
    pull_status="$(pull_image_if_needed "$image")"
    log_update "$SCRIPT_DIR" "api: $image — $pull_status"
  fi

  if ! container_needs_image "$name" "$image"; then
    log_update "$SCRIPT_DIR" "api: $name already on latest $image"
    return 0
  fi

  log_update "$SCRIPT_DIR" "api: updating $name (stop -t $stop_timeout)"
  graceful_stop "$name" "$stop_timeout"
  PULL=0 "$SCRIPT_DIR/start-hello-api.sh"
  log_update "$SCRIPT_DIR" "api: $name updated"
}

with_update_lock "$SCRIPT_DIR" "api" run_api_update
