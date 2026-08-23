#!/usr/bin/env bash
# Smoke checks before npm publish.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

test -x install.sh
test -x package.sh
test -f lib/fetch.sh
test -f lib/load_config.py
test -f lib/product_config.py
test -f lib/package.py
test -f templates/generic/start-api.sh
test -f schema/packageconfig.md

bash -n install.sh
bash -n start.sh
bash -n update.sh
bash -n package.sh

python3 -c "
import sys
from pathlib import Path
sys.path.insert(0, 'lib')
from product_config import load_product, compile_packageconfig
p = load_product(Path('examples/vps-hello'))
c = compile_packageconfig(p, raw_base='/dist')
assert c['profiles']['api']['role'] == 'backend'
assert c['profiles']['ui']['role'] == 'ui'
assert c['profiles']['gateway']['sites'][0]['host'] == 'hello.example.com'
print('product_config ok')
"

bash examples/vps-hello/package.sh
test -f examples/vps-hello/dist/install-api.sh
test -f examples/vps-hello/dist/packageconfig.yaml
test -x examples/vps-hello/dist/start-api.sh

for prof in api ui nodes gateway; do
  DEST="${TMPDIR:-/tmp}/hello-dist-dry-${prof}-$$"
  mkdir -p "$DEST"
  PACKAGER_RAW="$ROOT" INSTALL_DIR="$DEST" bash "examples/vps-hello/dist/install-${prof}.sh"
  test -f "$DEST/.env"
  test -x "$DEST/start-${prof}.sh" || test -x "$DEST/start-api.sh"
  rm -rf "$DEST"
done

python3 lib/generate.py examples/vps-hello/dist/packageconfig.yaml --profile gateway \
  -o /tmp/hello-vps-domains.conf
grep -q "hello.example.com" /tmp/hello-vps-domains.conf
grep -q "hello-vps-api:8080" /tmp/hello-vps-domains.conf

for f in \
  examples/vps-hello/package.sh \
  examples/vps-hello/build-images.sh \
  examples/vps-hello/test-dist.sh \
  examples/vps-hello/test/run.sh \
  examples/vps-hello/dist/install-api.sh \
  examples/vps-hello/dist/install-ui.sh \
  examples/vps-hello/dist/install-nodes.sh \
  examples/vps-hello/dist/install-gateway.sh
do
  bash -n "$f"
done

echo "vibed-infra package validation OK"
