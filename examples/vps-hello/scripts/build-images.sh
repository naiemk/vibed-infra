#!/usr/bin/env bash
# Build the three local images used by packageconfig.yaml.
set -euo pipefail
EXAMPLE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$EXAMPLE"
docker build -t hello-vps-api:local "$EXAMPLE/app/api"
docker build -t hello-vps-ui:local "$EXAMPLE/app/ui"
docker build -t hello-vps-worker:local "$EXAMPLE/app/worker"
echo "Built hello-vps-api:local hello-vps-ui:local hello-vps-worker:local"
