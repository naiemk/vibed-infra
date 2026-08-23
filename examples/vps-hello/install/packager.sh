#!/usr/bin/env bash
# Resolve vibed-infra + this example when run from a git checkout or via wget.
set -euo pipefail

_infra_install_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_infra_product_root="$(cd "$_infra_install_dir/.." && pwd)"
_infra_packager_root="$(cd "$_infra_product_root/../.." && pwd)"

_infra_resolve_packager() {
  if [[ -n "${PACKAGER_RAW:-}" ]]; then
    :
  elif [[ -x "$_infra_packager_root/install.sh" && -d "$_infra_packager_root/lib" ]]; then
    PACKAGER_RAW="$_infra_packager_root"
  else
    PACKAGER_RAW="https://raw.githubusercontent.com/naiemk/vibed-infra/main"
  fi
  if [[ "$PACKAGER_RAW" =~ ^/ ]]; then
    export PRODUCT_RAW="${PRODUCT_RAW:-${_infra_product_root}/templates}"
  fi
}

_infra_run_install() {
  local profile="$1"
  _infra_resolve_packager
  export PACKAGER_RAW
  export PRODUCT_RAW="${PRODUCT_RAW:-${_infra_product_root}/templates}"
  export PACKAGECONFIG_URL="${PACKAGECONFIG_URL:-${_infra_product_root}/packageconfig.yaml}"
  export INFRA_PROFILE="$profile"
  export INSTALL_DIR="${INSTALL_DIR:-.}"
  if [[ "$PACKAGER_RAW" =~ ^/ ]]; then
    exec bash "$PACKAGER_RAW/install.sh" --profile "$profile"
  fi
  if command -v curl >/dev/null 2>&1; then
    exec bash <(curl -fsSL "${PACKAGER_RAW}/install.sh") --profile "$profile"
  else
    exec bash <(wget -qO- "${PACKAGER_RAW}/install.sh") --profile "$profile"
  fi
}
