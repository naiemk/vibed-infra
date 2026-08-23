#!/usr/bin/env bash
# wget -qO- https://raw.githubusercontent.com/naiemk/vibed-infra/main/examples/vps-hello/install/install-api.sh | bash
set -euo pipefail
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -f "$_SCRIPT_DIR/packager.sh" ]]; then
  # shellcheck source=packager.sh
  source "$_SCRIPT_DIR/packager.sh"
  _infra_run_install api
fi
PACKAGER_RAW="${PACKAGER_RAW:-https://raw.githubusercontent.com/naiemk/vibed-infra/main}"
PACKAGECONFIG_URL="${PACKAGECONFIG_URL:-https://raw.githubusercontent.com/naiemk/vibed-infra/main/examples/vps-hello/packageconfig.yaml}"
PRODUCT_RAW="${PRODUCT_RAW:-https://raw.githubusercontent.com/naiemk/vibed-infra/main/examples/vps-hello/templates}"
export PACKAGER_RAW PACKAGECONFIG_URL PRODUCT_RAW INFRA_PROFILE=api INSTALL_DIR="${INSTALL_DIR:-.}"
if command -v curl >/dev/null 2>&1; then
  exec bash <(curl -fsSL "${PACKAGER_RAW}/install.sh") --profile api
else
  exec bash <(wget -qO- "${PACKAGER_RAW}/install.sh") --profile api
fi
