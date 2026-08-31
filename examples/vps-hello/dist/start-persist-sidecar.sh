#!/usr/bin/env bash
# Start (or recreate) the persist-log ship sidecar for one deployment.
# Usage: start-persist-sidecar.sh <app-container-name> <persist-volume-name>
# Requires: lib-env.sh sourced, machine persist-logs installed under VIBED_HOME.
set -euo pipefail

APP_NAME="${1:?app container name required}"
PERSIST_VOL="${2:?persist volume name required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Prefer install-dir helpers when invoked from a product start script cwd
if [[ -f ./lib-env.sh ]]; then
  # shellcheck source=/dev/null
  source ./lib-env.sh
elif [[ -f "${SCRIPT_DIR}/../../lib/env.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/../../lib/env.sh"
fi

SIDECAR_NAME="${APP_NAME}-persist-ship"
IMAGE="${PERSIST_SIDECAR_IMAGE:-python:3.12-alpine}"
MEMORY="${PERSIST_SIDECAR_MEMORY:-64m}"
VHOME="$(vibed_home_dir 2>/dev/null || echo "${HOME}/services/vibed-infra")"
PDIR="${VHOME}/persist-logs"

if [[ ! -f "${PDIR}/ship.py" ]]; then
  echo "warning: ${PDIR}/ship.py missing — skip persist sidecar (run install-persist-logs.sh)" >&2
  return 0 2>/dev/null || exit 0
fi

if [[ "${PULL_SIDECAR:-0}" == "1" && "$IMAGE" != *:local ]]; then
  docker pull "$IMAGE" >/dev/null 2>&1 || true
fi

if docker inspect "$SIDECAR_NAME" >/dev/null 2>&1; then
  docker rm -f "$SIDECAR_NAME" >/dev/null 2>&1 || true
fi

ENV_FILE_ARGS=()
if [[ -f "${PDIR}/.env" ]]; then
  ENV_FILE_ARGS+=(--env-file "${PDIR}/.env")
fi

LIB_MOUNT=()
if [[ -d "${PDIR}/lib/persistlog" ]]; then
  LIB_MOUNT+=(-v "${PDIR}/lib:/opt/vibed/lib:ro")
fi

# shellcheck disable=SC2046
docker run -d \
  --name "$SIDECAR_NAME" \
  --restart unless-stopped \
  --security-opt no-new-privileges \
  $(memory_args "$MEMORY" 2>/dev/null || echo --memory="$MEMORY") \
  --label "vibed.managed=1" \
  --label "vibed.role=persist-ship" \
  --label "vibed.persist-volume=${PERSIST_VOL}" \
  --label "vibed.app=${APP_NAME}" \
  -e "PERSIST_LOG_ROOT=/persist-logs" \
  -e "PERSIST_SHIP_PREFIX=${APP_NAME}" \
  "${ENV_FILE_ARGS[@]}" \
  -v "${PERSIST_VOL}:/persist-logs" \
  -v "${PDIR}/ship.py:/opt/vibed/ship.py:ro" \
  "${LIB_MOUNT[@]}" \
  "$IMAGE" \
  sh -c 'while true; do python3 /opt/vibed/ship.py || true; sleep 600; done' >/dev/null

echo "persist sidecar $SIDECAR_NAME up (volume $PERSIST_VOL)"
