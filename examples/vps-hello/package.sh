#!/usr/bin/env bash
# Proxy to vibed-infra packager — writes dist/ for wget VPS install.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGER="${PACKAGER_ROOT:-$(cd "$ROOT/../.." && pwd)}"
exec bash "$PACKAGER/package.sh" --product "$ROOT" --out "$ROOT/dist" --packager "$PACKAGER"
