#!/usr/bin/env bash
# Host driver: package dist, build images, install and prove profile api|ui|nodes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EXAMPLE="$(cd "$(dirname "$0")" && pwd)"
PROFILE="${1:-}"
if [[ "$PROFILE" == "--profile" ]]; then
  PROFILE="${2:-}"
fi
if [[ -z "$PROFILE" ]]; then
  echo "usage: $0 --profile api|ui|nodes" >&2
  exit 1
fi

bash "$EXAMPLE/package.sh"
bash "$EXAMPLE/build-images.sh"

export PROFILE
export TEST_SUFFIX="$PROFILE"
export TEST_BASE="/tmp/hello-${PROFILE}"
export PACKAGER_ROOT="$ROOT"
export DIST_DIR="$EXAMPLE/dist"
bash "$EXAMPLE/test/run.sh"

echo "test-dist profile=$PROFILE OK"
