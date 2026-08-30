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
assert c['profiles']['gateway'].get('publicIp') == '203.0.113.10'
assert c['profiles']['gateway'].get('tlsEmail') == 'ops@example.com'
print('product_config ok')
"

bash examples/vps-hello/package.sh
test -f examples/vps-hello/dist/install-api.sh
test -f examples/vps-hello/dist/packageconfig.yaml
test -f examples/vps-hello/dist/DNS-SKILL.md
grep -q "hello.example.com" examples/vps-hello/dist/DNS-SKILL.md
grep -q "203.0.113.10" examples/vps-hello/dist/DNS-SKILL.md
test -x examples/vps-hello/dist/start-api.sh

# Persistlog round-trip
python3 - <<'PY'
import sys, tempfile
from pathlib import Path
sys.path.insert(0, "lib")
from persistlog import append, seal, replay, iter_events
td = Path(tempfile.mkdtemp())
append(td, "notes", "note.created", {"body": "hi"}, fsync=False)
append(td, "notes", "note.created", {"body": "yo"}, fsync=False)
seal(td / "notes")
n = sum(1 for _ in iter_events(td, "notes"))
assert n == 2, n
def apply(e, s):
    return s + [e["payload"]["body"]]
assert replay(td, "notes", apply, []) == ["hi", "yo"]
print("persistlog ok")
PY

# Update queue enqueue smoke
bash -n templates/update-agent/agent.sh
bash -n templates/update-agent/install-agent.sh
bash -n lib/update_queue.sh
bash -n lib/host_gateway.sh

export GATEWAY_HOME="${TMPDIR:-/tmp}/vibed-gw-dry-$$"
export VIBED_HOME="${TMPDIR:-/tmp}/vibed-home-dry-$$"
mkdir -p "$GATEWAY_HOME" "$VIBED_HOME"
for prof in api ui nodes gateway; do
  DEST="${TMPDIR:-/tmp}/hello-dist-dry-${prof}-$$"
  mkdir -p "$DEST"
  PACKAGER_RAW="$ROOT" INSTALL_DIR="$DEST" GATEWAY_HOME="$GATEWAY_HOME" VIBED_HOME="$VIBED_HOME" \
    TLS_MODE=lab \
    bash "examples/vps-hello/dist/install-${prof}.sh"
  test -f "$DEST/.env"
  test -x "$DEST/start-${prof}.sh" || test -x "$DEST/start-api.sh"
  if [[ "$prof" == gateway ]]; then
    test -f "$GATEWAY_HOME/.vibed-host-gateway"
    test -f "$GATEWAY_HOME/apps/hello-vps/sites.conf"
    test -x "$GATEWAY_HOME/setup-tls.sh"
    bash -n "$GATEWAY_HOME/setup-tls.sh"
    test -f "$GATEWAY_HOME/certs/fullchain.pem"
    test -f "$GATEWAY_HOME/.vibed-tls-state"
    grep -q "hello.example.com" "$GATEWAY_HOME/apps/hello-vps/sites.conf"
  fi
  rm -rf "$DEST"
done
rm -rf "$GATEWAY_HOME" "$VIBED_HOME"

# DNS-SKILL bakes gateway.publicIp when set
grep -q "203.0.113.10" examples/vps-hello/dist/DNS-SKILL.md
grep -q "hello.example.com" examples/vps-hello/dist/DNS-SKILL.md

python3 lib/generate.py examples/vps-hello/dist/packageconfig.yaml --profile gateway --mode app \
  -o /tmp/hello-vps-sites.conf
grep -q "hello.example.com" /tmp/hello-vps-sites.conf
grep -q "hello-vps-api:8080" /tmp/hello-vps-sites.conf

# Queue seriality smoke
export VIBED_HOME="${TMPDIR:-/tmp}/vibed-q-$$"
# shellcheck source=/dev/null
source lib/update_queue.sh
vibed_enqueue_update "a" "api" "/tmp/x" "img:1" "test"
vibed_enqueue_update "a" "api" "/tmp/x" "img:1" "test"
n="$(find "$(vibed_agent_home)/queue" -name '*.json' | wc -l)"
[[ "$n" -eq 1 ]] || { echo "expected 1 queued job, got $n" >&2; exit 1; }
rm -rf "$VIBED_HOME"

for f in \
  examples/vps-hello/package.sh \
  examples/vps-hello/build-images.sh \
  examples/vps-hello/test-dist.sh \
  examples/vps-hello/test/run.sh \
  examples/vps-hello/dist/install-api.sh \
  examples/vps-hello/dist/install-ui.sh \
  examples/vps-hello/dist/install-nodes.sh \
  examples/vps-hello/dist/install-gateway.sh \
  templates/host-gateway/start-gateway.sh \
  templates/host-gateway/setup-tls.sh \
  templates/update-agent/agent.sh
do
  bash -n "$f"
done

echo "vibed-infra package validation OK"
