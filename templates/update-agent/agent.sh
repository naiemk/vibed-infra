#!/usr/bin/env bash
# Serial update agent — process one queued docker update at a time.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Prefer packager lib next to install, else sibling
if [[ -f "${SCRIPT_DIR}/../../lib/update_queue.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/../../lib/update_queue.sh"
elif [[ -f "${SCRIPT_DIR}/lib/update_queue.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/lib/update_queue.sh"
elif [[ -f "${HOME}/services/vibed-infra/update-agent/lib/update_queue.sh" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/services/vibed-infra/update-agent/lib/update_queue.sh"
fi

HOME_AGENT="$(vibed_queue_dirs)"
LOCK="${HOME_AGENT}/agent.lock"
LOG="${HOME_AGENT}/agent.log"

log() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG"
}

claim_one() {
  local f base
  shopt -s nullglob
  for f in "${HOME_AGENT}/queue"/*.json; do
    base="$(basename "$f")"
    if mv "$f" "${HOME_AGENT}/processing/${base}" 2>/dev/null; then
      echo "${HOME_AGENT}/processing/${base}"
      return 0
    fi
  done
  return 1
}

process_job() {
  local job="$1"
  local install_dir role update_script
  install_dir="$(python3 -c "import json;print(json.load(open('$job'))['installDir'])")"
  role="$(python3 -c "import json;print(json.load(open('$job'))['role'])")"
  app="$(python3 -c "import json;print(json.load(open('$job'))['app'])")"
  log "processing app=$app role=$role dir=$install_dir"
  if [[ ! -d "$install_dir" ]]; then
    log "missing install dir $install_dir"
    mv "$job" "${HOME_AGENT}/failed/$(basename "$job")"
    return 1
  fi
  update_script="update-${role}.sh"
  if [[ ! -x "${install_dir}/${update_script}" ]]; then
    update_script="update.sh"
  fi
  (
    cd "$install_dir"
    export UPDATE_SOURCE=agent
    # Force role auto-update on for agent-driven runs
    case "$role" in
      api) export API_AUTO_UPDATE=1 ;;
      ui) export UI_AUTO_UPDATE=1 ;;
      nodes) export NODES_AUTO_UPDATE=1 ;;
      gateway) export GATEWAY_AUTO_UPDATE=1 ;;
    esac
    /bin/bash "./${update_script}"
  )
  local rc=$?
  if [[ "$rc" -eq 0 ]]; then
    mv "$job" "${HOME_AGENT}/done/$(basename "$job")"
    log "done $app/$role"
  else
    mv "$job" "${HOME_AGENT}/failed/$(basename "$job")"
    log "failed $app/$role rc=$rc"
  fi
  return "$rc"
}

# Single-flight via flock
exec 9>"$LOCK"
if ! flock -n 9; then
  log "another agent holds lock — exit"
  exit 0
fi

while job="$(claim_one)"; do
  process_job "$job" || true
done
log "queue empty"
