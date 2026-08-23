#!/usr/bin/env bash
# Interactive / all-profiles wrapper for the hello-vps example.
set -euo pipefail
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -f "$_SCRIPT_DIR/install/packager.sh" ]]; then
  # shellcheck source=install/packager.sh
  source "$_SCRIPT_DIR/install/packager.sh"
  _infra_resolve_packager
  export PACKAGER_RAW
  export PRODUCT_RAW="${PRODUCT_RAW:-${_infra_product_root}/templates}"
  export PACKAGECONFIG_URL="${PACKAGECONFIG_URL:-${_infra_product_root}/packageconfig.yaml}"
  export INSTALL_DIR="${INSTALL_DIR:-.}"
  if [[ "$PACKAGER_RAW" =~ ^/ ]]; then
    exec bash "$PACKAGER_RAW/install.sh" "$@"
  fi
fi
PACKAGER_RAW="${PACKAGER_RAW:-https://raw.githubusercontent.com/naiemk/vibed-infra/main}"
PACKAGECONFIG_URL="${PACKAGECONFIG_URL:-https://raw.githubusercontent.com/naiemk/vibed-infra/main/examples/vps-hello/packageconfig.yaml}"
PRODUCT_RAW="${PRODUCT_RAW:-https://raw.githubusercontent.com/naiemk/vibed-infra/main/examples/vps-hello/templates}"
export PACKAGER_RAW PACKAGECONFIG_URL PRODUCT_RAW INSTALL_DIR="${INSTALL_DIR:-.}"
if command -v curl >/dev/null 2>&1; then
  exec bash <(curl -fsSL "${PACKAGER_RAW}/install.sh") "$@"
else
  exec bash <(wget -qO- "${PACKAGER_RAW}/install.sh") "$@"
fi
