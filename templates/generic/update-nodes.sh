#!/usr/bin/env bash
# Digest-gated worker update via compose.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=lib-env.sh
source "$SCRIPT_DIR/lib-env.sh"
load_dotenv .env

if ! role_auto_update_on NODES_AUTO_UPDATE; then
  exit 0
fi
if ! command -v docker >/dev/null 2>&1; then
  log_update "$SCRIPT_DIR" "nodes: docker not found"
  exit 1
fi

run_nodes_update() {
  local image name pull_status
  image="${WORKER_IMAGE:-ghcr.io/example/worker:main}"
  name="${WORKER_CONTAINER_NAME:-app-worker}"
  if [[ "$image" == *:local ]]; then
    log_update "$SCRIPT_DIR" "nodes: $image — skipped pull (local tag)"
  else
    pull_status="$(pull_image_if_needed "$image")"
    log_update "$SCRIPT_DIR" "nodes: $image — $pull_status"
  fi
  if ! container_needs_image "$name" "$image"; then
    log_update "$SCRIPT_DIR" "nodes: $name already on latest $image"
  else
    log_update "$SCRIPT_DIR" "nodes: updating via compose"
    PULL=0 "$SCRIPT_DIR/start-nodes.sh"
    log_update "$SCRIPT_DIR" "nodes: updated"
  fi
  prune_docker_images "$SCRIPT_DIR" "nodes"
}

with_update_lock "$SCRIPT_DIR" "nodes" run_nodes_update
