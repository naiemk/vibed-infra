#!/usr/bin/env bash
# Build product dist/ for VPS wget install.
#
#   bash package.sh --product examples/vps-hello --out examples/vps-hello/dist
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$ROOT/lib/package.py" --packager "$ROOT" "$@"
