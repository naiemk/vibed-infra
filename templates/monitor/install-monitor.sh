#!/usr/bin/env bash
# Install machine-wide monitor-vibed.sh under VIBED_HOME (idempotent overwrite).
set -euo pipefail
PACKAGER="${PACKAGER_RAW:-$(cd "$(dirname "$0")/../.." && pwd)}"
ROOT="${VIBED_HOME:-${HOME}/services/vibed-infra}"
ROOT="${ROOT/#\~/$HOME}"
mkdir -p "$ROOT"
SRC="${PACKAGER}/templates/monitor/monitor-vibed.sh"
if [[ ! -f "$SRC" ]]; then
  echo "warning: missing $SRC — skip monitor install" >&2
  exit 0
fi
cp -f "$SRC" "$ROOT/monitor-vibed.sh"
chmod +x "$ROOT/monitor-vibed.sh"
echo "monitor-vibed ready at $ROOT/monitor-vibed.sh"
