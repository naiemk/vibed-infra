#!/usr/bin/env bash
# Shared filesystem queue for serial docker updates across apps.
# shellcheck shell=bash

vibed_agent_home() {
  if [[ -n "${VIBED_UPDATE_AGENT:-}" ]]; then
    echo "${VIBED_UPDATE_AGENT}"
    return 0
  fi
  if [[ -n "${VIBED_HOME:-}" ]]; then
    echo "${VIBED_HOME}/update-agent"
    return 0
  fi
  if [[ -n "${HOME:-}" ]]; then
    echo "${HOME}/services/vibed-infra/update-agent"
    return 0
  fi
  echo "/var/lib/vibed/update-agent"
}

vibed_queue_dirs() {
  local home
  home="$(vibed_agent_home)"
  mkdir -p "$home/queue" "$home/processing" "$home/done" "$home/failed" "$home/registry"
  echo "$home"
}

# Enqueue an update job. Dedupes pending jobs with same app+role+image.
vibed_enqueue_update() {
  local app="$1" role="$2" install_dir="$3" image="${4:-}" reason="${5:-cron}"
  local home id key pending
  home="$(vibed_queue_dirs)"
  key="${app}:${role}:${image}"
  for pending in "$home/queue"/*.json; do
    [[ -f "$pending" ]] || continue
    if grep -q "\"dedupe\":\"${key}\"" "$pending" 2>/dev/null; then
      echo "already queued: $key"
      return 0
    fi
  done
  id="$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM}"
  cat >"$home/queue/${id}.json" <<EOF
{"id":"${id}","app":"${app}","role":"${role}","installDir":"${install_dir}","image":"${image}","reason":"${reason}","dedupe":"${key}","enqueuedAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
  echo "enqueued: $home/queue/${id}.json"
}

vibed_register_app() {
  local app="$1" role="$2" install_dir="$3" image="${4:-}"
  local home
  home="$(vibed_queue_dirs)"
  mkdir -p "$home/registry/${app}"
  cat >"$home/registry/${app}/${role}.json" <<EOF
{"app":"${app}","role":"${role}","installDir":"${install_dir}","image":"${image}","registeredAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
  echo "registered: ${app}/${role} → ${install_dir}"
}
