#!/usr/bin/env bash
set -euo pipefail
EXAMPLE="$(cd "$(dirname "$0")" && pwd)"
docker build -t hello-vps-api:local "$EXAMPLE/app/api"
docker build -t hello-vps-ui:local "$EXAMPLE/app/ui"
docker build -t hello-vps-worker:local "$EXAMPLE/app/worker"
echo "Built hello-vps-api:local hello-vps-ui:local hello-vps-worker:local"
