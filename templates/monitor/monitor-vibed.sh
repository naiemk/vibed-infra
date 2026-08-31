#!/usr/bin/env bash
# Machine-wide vibed deployment monitor (TUI).
# Installed to $VIBED_HOME/monitor-vibed.sh by any product install.
#
# Usage:
#   monitor-vibed.sh              # interactive
#   monitor-vibed.sh --list       # non-interactive list
#   monitor-vibed.sh --summary NAME
set -euo pipefail

FILTER_LABEL="vibed.managed=1"

usage() {
  cat <<'EOF'
Usage: monitor-vibed.sh [--list | --summary NAME]

Interactive (default):
  Up/Down  move    Enter select    q quit
  Submenu: Summary | See logs | See logs folder | See persist-logs
  While tailing: Tab or Ctrl+C back to submenu; q quit
EOF
}

list_containers() {
  docker ps -a --filter "label=${FILTER_LABEL}" --format '{{.Names}}' 2>/dev/null | sort
}

container_state() {
  local name="$1"
  docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "missing"
}

container_label() {
  local name="$1" key="$2"
  docker inspect -f "{{index .Config.Labels \"${key}\"}}" "$name" 2>/dev/null || true
}

container_image() {
  local name="$1"
  docker inspect -f '{{.Config.Image}}' "$name" 2>/dev/null || echo "?"
}

print_list() {
  local name role state
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    role="$(container_label "$name" "vibed.role")"
    state="$(container_state "$name")"
    printf '%-40s %-14s %s\n' "$name" "${role:-?}" "$state"
  done < <(list_containers)
}

print_summary() {
  local name="$1"
  local role state image data_vol logs_vol persist_vol
  if ! docker inspect "$name" >/dev/null 2>&1; then
    echo "container not found: $name" >&2
    return 1
  fi
  role="$(container_label "$name" "vibed.role")"
  state="$(container_state "$name")"
  image="$(container_image "$name")"
  data_vol="$(container_label "$name" "vibed.data-volume")"
  logs_vol="$(container_label "$name" "vibed.logs-volume")"
  persist_vol="$(container_label "$name" "vibed.persist-volume")"
  cat <<EOF
name:     $name
role:     ${role:-?}
status:   $state
image:    $image
data:     ${data_vol:-(none)}
logs:     ${logs_vol:-(none)}
persist:  ${persist_vol:-(none)}
EOF
}

# Tail docker logs until Tab/Ctrl+C; returns 0=back, 1=quit
tail_docker_logs() {
  local name="$1"
  echo "=== docker logs -f $name (Tab/Ctrl+C back, q quit) ==="
  local rc=0
  set +e
  docker logs -f --tail 200 "$name" &
  local pid=$!
  _wait_interrupt "$pid"
  rc=$?
  set -e
  return "$rc"
}

# Follow text files inside a named volume.
tail_volume_files() {
  local vol="$1"
  local title="$2"
  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    echo "volume missing: $vol" >&2
    sleep 1
    return 0
  fi
  echo "=== $title volume $vol (Tab/Ctrl+C back, q quit) ==="
  set +e
  docker run --rm -i \
    -v "${vol}:/mnt:ro" \
    alpine sh -c '
      set -e
      # Prefer common log paths; fall back to any *.log / wal / seg
      files=""
      for p in /mnt /mnt/* /mnt/*/*; do
        [ -e "$p" ] || continue
      done
      files=$(find /mnt -type f \( -name "wal.ndjson" -o -name "*.log" -o -name "seg-*.ndjson.gz" -o -name "*.ndjson" \) 2>/dev/null | head -20)
      if [ -z "$files" ]; then
        echo "(no log files yet — listing volume)"
        ls -laR /mnt 2>/dev/null || true
        # Keep container alive until killed so Tab still works
        while true; do sleep 3600; done
      fi
      # shellcheck disable=SC2086
      exec tail -n 200 -F $files
    ' &
  local pid=$!
  _wait_interrupt "$pid"
  local rc=$?
  set -e
  return "$rc"
}

# Wait for Tab (\\t), q, or Ctrl+C while background pid runs.
# Returns 0 = back to menu, 1 = quit
_wait_interrupt() {
  local pid="$1"
  local key
  # Ensure we can read single keys
  if [[ -t 0 ]]; then
    stty -echo -icanon time 0 min 0 2>/dev/null || true
  fi
  trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; if [[ -t 0 ]]; then stty sane 2>/dev/null || true; fi; return 0' INT
  while kill -0 "$pid" 2>/dev/null; do
    key=""
    if [[ -t 0 ]]; then
      IFS= read -r -n 1 key || true
    else
      sleep 0.2
      continue
    fi
    case "$key" in
      $'\t')
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        [[ -t 0 ]] && stty sane 2>/dev/null || true
        trap - INT
        return 0
        ;;
      q|Q)
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        [[ -t 0 ]] && stty sane 2>/dev/null || true
        trap - INT
        return 1
        ;;
    esac
    sleep 0.05
  done
  wait "$pid" 2>/dev/null || true
  [[ -t 0 ]] && stty sane 2>/dev/null || true
  trap - INT
  return 0
}

draw_list() {
  local -n _items=$1
  local idx="$2"
  local i
  clear 2>/dev/null || printf '\033[H\033[2J'
  echo "vibed monitor — deployments (↑/↓ Enter  q quit)"
  echo "----------------------------------------------"
  if [[ ${#_items[@]} -eq 0 ]]; then
    echo "(no vibed.managed containers)"
    return
  fi
  for i in "${!_items[@]}"; do
    local name="${_items[$i]}"
    local role state mark
    role="$(container_label "$name" "vibed.role")"
    state="$(container_state "$name")"
    mark=" "
    [[ "$i" -eq "$idx" ]] && mark=">"
    printf '%s %-36s %-12s %s\n' "$mark" "$name" "${role:-?}" "$state"
  done
}

draw_submenu() {
  local name="$1"
  local idx="$2"
  shift 2
  local -a opts=("$@")
  local i mark
  clear 2>/dev/null || printf '\033[H\033[2J'
  echo "vibed monitor — $name"
  print_summary "$name" | sed 's/^/  /'
  echo "----------------------------------------------"
  for i in "${!opts[@]}"; do
    mark=" "
    [[ "$i" -eq "$idx" ]] && mark=">"
    printf '%s %s\n' "$mark" "${opts[$i]}"
  done
  echo
  echo "↑/↓ Enter   Tab back   q quit"
}

submenu_for() {
  local name="$1"
  local -a opts=("Summary" "See logs")
  local logs_vol persist_vol
  logs_vol="$(container_label "$name" "vibed.logs-volume")"
  persist_vol="$(container_label "$name" "vibed.persist-volume")"
  [[ -n "$logs_vol" ]] && opts+=("See logs folder")
  [[ -n "$persist_vol" ]] && opts+=("See persist-logs")
  opts+=("Back")

  local idx=0
  while true; do
    draw_submenu "$name" "$idx" "${opts[@]}"
    local key
    IFS= read -r -n 1 key || true
    case "$key" in
      $'\x1b')
        read -r -n 2 -t 0.1 rest || true
        case "$rest" in
          '[A') ((idx > 0)) && idx=$((idx - 1)) ;;
          '[B') ((idx < ${#opts[@]} - 1)) && idx=$((idx + 1)) ;;
        esac
        ;;
      k) ((idx > 0)) && idx=$((idx - 1)) ;;
      j) ((idx < ${#opts[@]} - 1)) && idx=$((idx + 1)) ;;
      $'\t') return 0 ;;
      q|Q) return 1 ;;
      '')
        local choice="${opts[$idx]}"
        case "$choice" in
          Summary)
            clear 2>/dev/null || true
            print_summary "$name"
            echo
            echo "(Tab/Enter back)"
            while true; do
              IFS= read -r -n 1 k2 || true
              case "$k2" in $'\t'|''|q|Q) break ;; esac
            done
            [[ "$k2" == q || "$k2" == Q ]] && return 1
            ;;
          "See logs")
            clear 2>/dev/null || true
            if ! tail_docker_logs "$name"; then return 1; fi
            ;;
          "See logs folder")
            clear 2>/dev/null || true
            if ! tail_volume_files "$logs_vol" "logs folder"; then return 1; fi
            ;;
          "See persist-logs")
            clear 2>/dev/null || true
            if ! tail_volume_files "$persist_vol" "persist-logs"; then return 1; fi
            ;;
          Back) return 0 ;;
        esac
        ;;
    esac
  done
}

interactive() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker is required" >&2
    exit 1
  fi
  local -a items=()
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] && items+=("$name")
  done < <(list_containers)

  local idx=0
  while true; do
    # Refresh list each loop
    items=()
    while IFS= read -r name; do
      [[ -n "$name" ]] && items+=("$name")
    done < <(list_containers)
    if [[ ${#items[@]} -eq 0 ]]; then
      draw_list items 0
      echo
      echo "q quit"
      IFS= read -r -n 1 key || true
      [[ "$key" == q || "$key" == Q ]] && return 0
      continue
    fi
    ((idx >= ${#items[@]})) && idx=$((${#items[@]} - 1))
    draw_list items "$idx"
    local key rest
    IFS= read -r -n 1 key || true
    case "$key" in
      $'\x1b')
        read -r -n 2 -t 0.1 rest || true
        case "$rest" in
          '[A') ((idx > 0)) && idx=$((idx - 1)) ;;
          '[B') ((idx < ${#items[@]} - 1)) && idx=$((idx + 1)) ;;
        esac
        ;;
      k) ((idx > 0)) && idx=$((idx - 1)) ;;
      j) ((idx < ${#items[@]} - 1)) && idx=$((idx + 1)) ;;
      q|Q) return 0 ;;
      '')
        if ! submenu_for "${items[$idx]}"; then
          return 0
        fi
        ;;
    esac
  done
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --list) print_list; exit 0 ;;
    --summary)
      shift
      print_summary "${1:?NAME required}"
      exit $?
      ;;
    "")
      interactive
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
