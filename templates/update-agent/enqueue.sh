#!/usr/bin/env bash
# Enqueue update for current install dir (called from cron instead of update-*.sh).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${1:-.}"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"

PACKAGER="${PACKAGER_RAW:-}"
if [[ -z "$PACKAGER" && -f "${SCRIPT_DIR}/../../lib/update_queue.sh" ]]; then
  PACKAGER="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fi
# shellcheck source=/dev/null
source "${PACKAGER}/lib/update_queue.sh"

PROFILE=""
ROLE=""
if [[ -f "${INSTALL_DIR}/.infra-profile" ]]; then
  # shellcheck source=/dev/null
  source "${INSTALL_DIR}/.infra-profile"
fi
ROLE="${ROLE:-api}"
case "$ROLE" in
  backend) ROLE=api ;;
  workers) ROLE=nodes ;;
esac

APP="app"
if [[ -f "${INSTALL_DIR}/.packageconfig.yaml" ]]; then
  APP="$(python3 -c "import sys;sys.path.insert(0,'.');from pathlib import Path
# minimal parse
import re
t=Path('${INSTALL_DIR}/.packageconfig.yaml').read_text()
m=re.search(r'^name:\s*(\S+)',t,re.M)
print(m.group(1) if m else 'app')")"
fi

IMAGE=""
# shellcheck source=/dev/null
[[ -f "${INSTALL_DIR}/.env" ]] && set -a && source "${INSTALL_DIR}/.env" && set +a || true
case "$ROLE" in
  api) IMAGE="${BACKEND_IMAGE:-}" ;;
  ui) IMAGE="${UI_IMAGE:-}" ;;
  nodes) IMAGE="${WORKER_IMAGE:-}" ;;
  gateway) IMAGE="${NGINX_IMAGE:-}" ;;
esac

vibed_register_app "$APP" "$ROLE" "$INSTALL_DIR" "$IMAGE"
vibed_enqueue_update "$APP" "$ROLE" "$INSTALL_DIR" "$IMAGE" "${UPDATE_REASON:-cron}"

# Kick agent if idle
AGENT_HOME="$(vibed_agent_home)"
if [[ -x "${AGENT_HOME}/agent.sh" ]]; then
  /bin/bash "${AGENT_HOME}/agent.sh" &
fi
