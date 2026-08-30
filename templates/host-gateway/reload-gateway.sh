#!/usr/bin/env bash
# Reload host gateway config by recreating the container with fresh apps/*/sites.conf.
# Same ports; no second bind.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
PULL=0 exec "$SCRIPT_DIR/start-gateway.sh"
