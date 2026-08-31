# shellcheck shell=bash
# Environment helpers for infra packager.

load_dotenv() {
  local env_file="${1:-.env}"
  [[ -f "$env_file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
    local key="${line%%=*}"
    local val="${line#*=}"
    key="${key%%[[:space:]]*}"
    key="${key##[[:space:]]*}"
    key="${key%$'\r'}"
    val="${val%$'\r'}"
    if [[ "$val" =~ ^\"(.*)\"$ ]]; then val="${BASH_REMATCH[1]}"; fi
    if [[ "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
    [[ -z "$key" || "$key" == *[!A-Za-z0-9_]* ]] && continue
    if [[ -z "${!key-}" ]]; then
      export "$key=$val"
    fi
  done <"$env_file"
}

env_flag_on() {
  local name="$1"
  local val="${!name-}"
  case "$val" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

role_auto_update_on() {
  local primary="$1"
  if [[ -n "${!primary+x}" ]]; then
    env_flag_on "$primary"
    return
  fi
  env_flag_on AUTO_UPDATE
}

any_auto_update_on() {
  local flag
  for flag in "$@"; do
    if role_auto_update_on "$flag"; then
      return 0
    fi
  done
  return 1
}

append_missing_env_keys() {
  local example="$1"
  local envfile="$2"
  shift 2
  [[ -f "$example" && -f "$envfile" ]] || return 0
  local key line added=0
  local legacy_off=0
  if grep -qiE "^[[:space:]]*AUTO_UPDATE=(0|false|off)\b" "$envfile"; then
    legacy_off=1
  fi
  for key in "$@"; do
    if grep -qE "^[[:space:]]*${key}=" "$envfile"; then
      continue
    fi
    line="$(grep -E "^[[:space:]]*${key}=" "$example" | head -1 || true)"
    [[ -n "$line" ]] || continue
    if [[ "$legacy_off" -eq 1 && "$key" == *_AUTO_UPDATE ]]; then
      line="${key}=0"
    fi
    if [[ "$added" -eq 0 ]]; then
      {
        echo ""
        echo "# --- Auto-update (added by infra install; see .env.example) ---"
      } >>"$envfile"
    fi
    echo "$line" >>"$envfile"
    echo "appended to .env: $key"
    added=1
  done
}

log_update() {
  local dir="${1:-.}"
  local msg="$2"
  mkdir -p "$dir/logs"
  local line
  line="$(date -u +"%Y-%m-%dT%H:%M:%SZ") $msg"
  echo "$line" | tee -a "$dir/logs/auto-update.log"
}

resolve_update_lock_file() {
  if [[ -n "${UPDATE_LOCK_FILE:-}" ]]; then
    echo "$UPDATE_LOCK_FILE"
    return 0
  fi
  if [[ -d /var/lock && -w /var/lock ]]; then
    echo /var/lock/infra-auto-update.lock
    return 0
  fi
  echo /tmp/infra-auto-update.lock
}

with_update_lock() {
  local log_dir="$1"
  local role_label="$2"
  local fn="$3"
  local lock
  lock="$(resolve_update_lock_file)"
  exec 9>"$lock" || {
    log_update "$log_dir" "${role_label}: cannot open lock $lock — proceeding without flock"
    "$fn"
    return $?
  }
  if ! flock -n 9; then
    log_update "$log_dir" "${role_label}: another auto-update holds $lock — skip"
    exec 9>&-
    return 0
  fi
  "$fn"
  local rc=$?
  flock -u 9 2>/dev/null || true
  exec 9>&-
  return "$rc"
}

local_image_id() {
  local image="$1"
  docker image inspect -f '{{.Id}}' "$image" 2>/dev/null || true
}

remote_image_digest() {
  local image="$1"
  local digest="" out
  if out="$(docker buildx imagetools inspect "$image" --format '{{.Manifest.Digest}}' 2>/dev/null)"; then
    digest="$(printf '%s\n' "$out" | tr -d '[:space:]')"
  fi
  if [[ "$digest" != sha256:* ]]; then
    if out="$(docker buildx imagetools inspect "$image" -f '{{.Manifest.Digest}}' 2>/dev/null)"; then
      digest="$(printf '%s\n' "$out" | tr -d '[:space:]')"
    fi
  fi
  if [[ "$digest" != sha256:* ]]; then
    if out="$(docker buildx imagetools inspect "$image" 2>/dev/null)"; then
      digest="$(printf '%s\n' "$out" | awk '/^Digest:/{print $2; exit}')"
    fi
  fi
  if [[ "$digest" == sha256:* ]]; then
    echo "$digest"
  fi
}

local_repo_digest() {
  local image="$1"
  docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$image" 2>/dev/null \
    | sed -n 's/.*@//p' \
    | head -1
}

pull_image_if_needed() {
  local image="$1"
  local remote locald
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    docker pull "$image" >/dev/null
    echo "pulled (missing locally)"
    return 0
  fi
  remote="$(remote_image_digest "$image")"
  if [[ -z "$remote" ]]; then
    docker pull "$image" >/dev/null
    echo "pulled (digest probe unavailable)"
    return 0
  fi
  locald="$(local_repo_digest "$image")"
  if [[ -n "$locald" && "$locald" == "$remote" ]]; then
    echo "skipped (already $remote)"
    return 0
  fi
  docker pull "$image" >/dev/null
  echo "pulled ($remote)"
}

container_needs_image() {
  local name="$1"
  local image="$2"
  if ! docker inspect "$name" >/dev/null 2>&1; then
    return 0
  fi
  local running new
  running="$(docker inspect -f '{{.Image}}' "$name" 2>/dev/null || true)"
  new="$(docker image inspect -f '{{.Id}}' "$image" 2>/dev/null || true)"
  [[ -z "$running" || -z "$new" || "$running" != "$new" ]]
}

graceful_stop() {
  local name="$1"
  local timeout="${2:-180}"
  if docker inspect "$name" >/dev/null 2>&1; then
    docker stop -t "$timeout" "$name" >/dev/null 2>&1 || true
  fi
}

memory_args() {
  local limit="${1:-}"
  if [[ -n "$limit" ]]; then
    echo --memory="$limit"
  fi
}

chown_data_dir() {
  # Legacy bind-mount helper (DATA_BIND=1). Named volumes do not use this.
  local dir="$1"
  local uid="${2:-1000}"
  mkdir -p "$dir"
  if [[ "$(id -u)" -eq 0 ]]; then
    chown -R "${uid}:${uid}" "$dir" || true
  elif command -v sudo >/dev/null 2>&1; then
    sudo chown -R "${uid}:${uid}" "$dir" 2>/dev/null || \
      echo "warning: could not chown $dir to ${uid} — fix if container cannot write" >&2
  else
    echo "warning: ensure $dir is writable by uid ${uid}" >&2
  fi
  chmod 755 "$dir" 2>/dev/null || true
}

# Create a durable named volume (idempotent). Never removes existing volumes.
# Sets VIBED_VOLUME_CREATED=1 when a new volume was created, else 0.
# Extra label key=value pairs after role/container are optional.
vibed_ensure_volume() {
  local name="$1"
  local role="${2:-}"
  local container="${3:-}"
  shift 3 || true
  VIBED_VOLUME_CREATED=0
  local -a labels=(--label "vibed.managed=1")
  [[ -n "$role" ]] && labels+=(--label "vibed.role=${role}")
  [[ -n "$container" ]] && labels+=(--label "vibed.container=${container}")
  local kv
  for kv in "$@"; do
    [[ -n "$kv" ]] && labels+=(--label "$kv")
  done
  if docker volume inspect "$name" >/dev/null 2>&1; then
    return 0
  fi
  docker volume create "${labels[@]}" "$name" >/dev/null
  VIBED_VOLUME_CREATED=1
}

# True if dir exists and has any entries (including hidden except . and ..).
_vibed_host_dir_has_files() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  local f
  for f in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [[ -e "$f" ]] && return 0
  done
  return 1
}

# One-time copy from a legacy host bind dir into a newly created empty named volume.
# Do NOT mount the volume before the app unless migrating — any first mount can
# initialize ownership from that helper image instead of the app image.
vibed_migrate_host_dir() {
  local vol="$1"
  local host_dir="$2"
  local newly_created="${3:-0}"
  [[ -n "$vol" && -n "$host_dir" ]] || return 0
  [[ "$newly_created" == "1" ]] || return 0
  _vibed_host_dir_has_files "$host_dir" || return 0
  local abs
  abs="$(cd "$host_dir" && pwd)"
  echo "Migrating $abs → volume $vol (keeping host copy) ..."
  docker run --rm \
    -v "${vol}:/dest" \
    -v "${abs}:/src:ro" \
    alpine sh -c 'cp -a /src/. /dest/' >/dev/null
}

# Resolve data storage: named volume (default) vs host bind (DATA_BIND=1 or non-default DATA_DIR).
# Sets: VIBED_DATA_MODE=volume|bind, VIBED_DATA_VOLUME, VIBED_DATA_BIND_PATH
vibed_resolve_data_storage() {
  local container_name="$1"
  local role="${2:-api}"
  VIBED_DATA_MODE=volume
  VIBED_DATA_VOLUME="${DATA_VOLUME:-${container_name}-data}"
  VIBED_DATA_BIND_PATH=""
  if env_flag_on DATA_BIND; then
    VIBED_DATA_MODE=bind
    VIBED_DATA_BIND_PATH="${DATA_DIR:-./data}"
    return 0
  fi
  local dd="${DATA_DIR-}"
  if [[ -n "$dd" && "$dd" != "./data" && "$dd" != "data" ]]; then
    VIBED_DATA_MODE=bind
    VIBED_DATA_BIND_PATH="$dd"
    return 0
  fi
  vibed_ensure_volume "$VIBED_DATA_VOLUME" "$role" "$container_name" "vibed.kind=data"
  if [[ -z "$dd" || "$dd" == "./data" || "$dd" == "data" ]]; then
    vibed_migrate_host_dir "$VIBED_DATA_VOLUME" "./data" "${VIBED_VOLUME_CREATED:-0}"
  fi
}

# Persist logs: default named volume + sidecar. PERSIST_LOGS=0 disables.
# Sets: VIBED_PERSIST_MODE=volume|bind|off, VIBED_PERSIST_VOLUME, VIBED_PERSIST_BIND_PATH
vibed_resolve_persist_storage() {
  local container_name="$1"
  local role="${2:-api}"
  VIBED_PERSIST_MODE=volume
  VIBED_PERSIST_VOLUME="${PERSIST_LOG_VOLUME:-${container_name}-persist}"
  VIBED_PERSIST_BIND_PATH=""
  if [[ -n "${PERSIST_LOGS+x}" ]] && ! env_flag_on PERSIST_LOGS; then
    VIBED_PERSIST_MODE=off
    return 0
  fi
  if env_flag_on PERSIST_LOG_BIND; then
    VIBED_PERSIST_MODE=bind
    VIBED_PERSIST_BIND_PATH="${PERSIST_LOG_DIR:-./persist-logs}"
    return 0
  fi
  local pd="${PERSIST_LOG_DIR-}"
  if [[ -n "$pd" && "$pd" != "./persist-logs" && "$pd" != "persist-logs" ]]; then
    VIBED_PERSIST_MODE=bind
    VIBED_PERSIST_BIND_PATH="$pd"
    return 0
  fi
  vibed_ensure_volume "$VIBED_PERSIST_VOLUME" "$role" "$container_name" "vibed.kind=persist"
  if [[ -z "$pd" || "$pd" == "./persist-logs" || "$pd" == "persist-logs" ]]; then
    vibed_migrate_host_dir "$VIBED_PERSIST_VOLUME" "./persist-logs" "${VIBED_VOLUME_CREATED:-0}"
  fi
}

# Worker logs volume (default) or bind.
# Sets: VIBED_LOGS_MODE=volume|bind, VIBED_LOGS_VOLUME, VIBED_LOGS_BIND_PATH
vibed_resolve_logs_storage() {
  local container_name="$1"
  local role="${2:-nodes}"
  VIBED_LOGS_MODE=volume
  VIBED_LOGS_VOLUME="${WORKER_LOG_VOLUME:-${container_name}-logs}"
  VIBED_LOGS_BIND_PATH=""
  if env_flag_on LOGS_BIND; then
    VIBED_LOGS_MODE=bind
    VIBED_LOGS_BIND_PATH="${LOGS_DIR:-./logs}"
    return 0
  fi
  local ld="${LOGS_DIR-}"
  if [[ -n "$ld" && "$ld" != "./logs" && "$ld" != "logs" ]]; then
    VIBED_LOGS_MODE=bind
    VIBED_LOGS_BIND_PATH="$ld"
    return 0
  fi
  vibed_ensure_volume "$VIBED_LOGS_VOLUME" "$role" "$container_name" "vibed.kind=logs"
  if [[ -z "$ld" || "$ld" == "./logs" || "$ld" == "logs" ]]; then
    vibed_migrate_host_dir "$VIBED_LOGS_VOLUME" "./logs" "${VIBED_VOLUME_CREATED:-0}"
  fi
}

vibed_home_dir() {
  if [[ -n "${VIBED_HOME:-}" ]]; then
    echo "${VIBED_HOME/#\~/$HOME}"
    return 0
  fi
  echo "${HOME}/services/vibed-infra"
}

# Default on during auto-update. Set DOCKER_AUTO_PRUNE=0 to disable.
docker_auto_prune_on() {
  if [[ -n "${DOCKER_AUTO_PRUNE+x}" ]]; then
    env_flag_on DOCKER_AUTO_PRUNE
    return
  fi
  return 0
}

# Drop dangling images left after retagged pulls (e.g. :main). Optionally also
# remove unused tagged images older than DOCKER_PRUNE_UNTIL when DOCKER_PRUNE_UNUSED=1.
prune_docker_images() {
  local log_dir="${1:-.}"
  local role_label="${2:-infra}"
  docker_auto_prune_on || return 0
  if ! command -v docker >/dev/null 2>&1; then
    return 0
  fi
  local summary
  summary="$(docker image prune -f 2>/dev/null | awk '/Total reclaimed space/{print; found=1} END{if(!found) print "done"}' || echo done)"
  log_update "$log_dir" "${role_label}: prune dangling images — ${summary}"
  if env_flag_on DOCKER_PRUNE_UNUSED; then
    local until="${DOCKER_PRUNE_UNTIL:-72h}"
    summary="$(docker image prune -af --filter "until=${until}" 2>/dev/null \
      | awk '/Total reclaimed space/{print; found=1} END{if(!found) print "done"}' || echo done)"
    log_update "$log_dir" "${role_label}: prune unused images (until=${until}) — ${summary}"
  fi
}
