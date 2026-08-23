# shellcheck shell=bash
# Interactive component picker (TTY only).

infra_pick_profile() {
  if [[ -n "${INFRA_PROFILE:-}" ]]; then
    echo "$INFRA_PROFILE"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "Set INFRA_PROFILE=api|ui|nodes|gateway (or pass --profile) when piping install.sh" >&2
    return 1
  fi
  echo "Select component to install:" >&2
  echo "  1) API (backend)" >&2
  echo "  2) UI" >&2
  echo "  3) Workers (nodes)" >&2
  echo "  4) Gateway (HTTPS nginx)" >&2
  local choice
  read -r -p "Choice [1-4]: " choice
  case "$choice" in
    1|api|backend) echo "api" ;;
    2|ui) echo "ui" ;;
    3|nodes|workers) echo "nodes" ;;
    4|gateway) echo "gateway" ;;
    *) echo "Invalid choice" >&2; return 1 ;;
  esac
}
