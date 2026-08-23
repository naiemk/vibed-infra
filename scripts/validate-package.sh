#!/usr/bin/env bash
# Smoke checks before npm publish.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

test -x install.sh
test -f lib/fetch.sh
test -f lib/load_config.py
test -f templates/docker-compose.backend.yml
test -f schema/packageconfig.md

# install.sh must parse
bash -n install.sh
bash -n start.sh
bash -n update.sh

# generate.py loads
python3 lib/generate.py --help >/dev/null 2>&1 || python3 -c "
import sys
from pathlib import Path
sys.path.insert(0, 'lib')
from load_config import load_packageconfig
print('load_config ok')
"

# Example product: stdlib YAML + generated gateway conf + install dry-run
python3 - <<'PY'
from pathlib import Path
import sys
sys.path.insert(0, "lib")
from load_config import _parse_minimal, get_profile

text = Path("examples/vps-hello/packageconfig.yaml").read_text(encoding="utf-8")
conf = _parse_minimal(text)
assert get_profile(conf, "api")["role"] == "backend"
assert get_profile(conf, "nodes")["role"] == "workers"
assert get_profile(conf, "gateway")["sites"][0]["host"] == "hello.example.com"
print("example packageconfig (minimal parser) ok")
PY

python3 lib/generate.py examples/vps-hello/packageconfig.yaml --profile gateway \
  -o /tmp/hello-vps-domains.conf
grep -q "hello.example.com" /tmp/hello-vps-domains.conf
grep -q "hello-api:8080" /tmp/hello-vps-domains.conf

for f in \
  examples/vps-hello/install.sh \
  examples/vps-hello/install/packager.sh \
  examples/vps-hello/install/install-api.sh \
  examples/vps-hello/install/install-nodes.sh \
  examples/vps-hello/install/install-gateway.sh \
  examples/vps-hello/templates/start-hello-api.sh \
  examples/vps-hello/templates/start-hello-nodes.sh \
  examples/vps-hello/templates/start-hello-gateway.sh \
  examples/vps-hello/templates/update-hello-api.sh \
  examples/vps-hello/templates/update-hello-nodes.sh \
  examples/vps-hello/templates/update-hello-gateway.sh \
  examples/vps-hello/scripts/try-install.sh \
  examples/vps-hello/scripts/build-images.sh \
  examples/vps-hello/scripts/gen-dev-certs.sh
do
  bash -n "$f"
done

bash examples/vps-hello/scripts/try-install.sh

echo "vibed-infra package validation OK"
